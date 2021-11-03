/*
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see http://www.gnu.org/licenses/.
 */

#include <sourcemod>
#include <sdktools>
#include <latedl2s>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_NAME "Resizable Sprays"
#define PLUGIN_DESC "Extends default sprays to allow for scaling and spamming"
#define PLUGIN_AUTHOR "Sappykun"
#define PLUGIN_VERSION "3.0.0-RC3"
#define PLUGIN_URL "https://forums.alliedmods.net/showthread.php?t=332418"

// Normal sprays are 64 Hammer units tall
#define SPRAY_UNIT_DIMENSION_FLOAT 64.0

char g_vmtTemplate[512] = "LightmappedGeneric\n\
{\n\
\t$basetexture \"temp/%s\"\n\
\t$decalscale %.4f\n\
\t$spriteorientation 3\n\
\t$spriteorigin \"[ 0.50 0.50 ]\"\n\
\t$vertexcolor 1\n\
\t$vertexalpha 1\n\
\t$translucent 1\n\
\t$decal 1\n\
\t$decalsecondpass 1\n\
\tProxies\n\
\t{\n\
\t\tPlayerLogo {}\n\
\t\tAnimatedTexture\n\
\t\t{\n\
\t\t\tanimatedtexturevar $basetexture\n\
\t\t\tanimatedtextureframenumvar $frame\n\
\t\t\tanimatedtextureframerate 5\n\
\t\t}\n\
\t}\n\
}";

enum struct Player {
	StringMap DatQueue;
	bool bSprayHasBeenProcessed;
	bool bIsReadyToSpray;
	int iSprayHeight;
	float fScale; //last scale used
	float fLastSprayed;
	float fRealSprayLastPosition[3];
	char sSprayFile[12];
	char sSprayFilePath[PLATFORM_MAX_PATH];
}

enum struct Material {
	int iReady;
	int iPrecache; // Given precache ID
	int iClientsSuccess[MAXPLAYERS + 1];
	int iClientsFailure[MAXPLAYERS + 1];
	float fScaleReal; // The real scale factor based on spray dimensions + clamping
}

enum struct Spray {
	int iSprayer; // for sound emission
	int iClient;
	int iEntity;
	int iHitbox;
	int iDecalType;
	float fSprayTime; // when was this request made
	float fPosition[3];
	char sMaterialName[64];
}

Player g_Players[MAXPLAYERS + 1];
ArrayList g_SprayQueue;
StringMap g_mapMaterials;

ConVar cv_bEnabled;
ConVar cv_sAdminFlags;
ConVar cv_fMaxSprayScale;
ConVar cv_fMaxSprayDistance;
ConVar cv_fDecalFrequency;
ConVar cv_fSprayTimeout;

char g_strLogFile[PLATFORM_MAX_PATH];

bool g_bBuffer; // Catch-all garbage buffer for StringMaps

public Plugin myinfo =
{
	name = PLUGIN_NAME,
	description = PLUGIN_DESC,
	author = PLUGIN_AUTHOR,
	version = PLUGIN_VERSION,
	url = PLUGIN_URL
}

public void OnPluginStart()
{
	RegConsoleCmd("sm_spray", Command_Spray, "Places a repeatable, scalable version of your spray as a decal.");
	RegConsoleCmd("sm_bspray", Command_Spray, "Places a repeatable, scalable version of your spray as a BSP decal.");

	CreateConVar("rspr_version", PLUGIN_VERSION, "Resizable Sprays version. Don't touch this.", FCVAR_NOTIFY|FCVAR_DONTRECORD|FCVAR_SPONLY);

	cv_bEnabled = CreateConVar("rspr_enabled", "1.0", "Enables the plugin.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_sAdminFlags = CreateConVar("rspr_adminflags", "b", "Admin flags required to bypass restrictions", FCVAR_NONE, false, 0.0, false, 0.0);
	cv_fMaxSprayDistance = CreateConVar("rspr_maxspraydistance", "128.0", "Max range for placing decals. 0 is infinite range", FCVAR_NOTIFY, true, 0.0, false);
	cv_fMaxSprayScale = CreateConVar("rspr_maxsprayscale", "2.0", "Maximum scale for sprays.", FCVAR_NOTIFY, true, 0.0, false, 0.0);
	cv_fDecalFrequency = CreateConVar("rspr_decalfrequency", "0.5", "Spray frequency for non-admins. 0 is no delay.", FCVAR_NOTIFY, true, 0.0, false);
	cv_fSprayTimeout = CreateConVar("rspr_spraytimeout", "10.0", "Max time to wait for clients to download spray files. 0 to wait forever.", FCVAR_NOTIFY, true, 0.0, false);

	AddTempEntHook("Player Decal", PlayerSprayReal);

	AutoExecConfig(true, "resizablesprays");
	LoadTranslations("common.phrases");

	char timebuffer[32];
	FormatTime(timebuffer, sizeof(timebuffer), "%F", GetTime());
	BuildPath(Path_SM, g_strLogFile, sizeof(g_strLogFile), "logs/rspr_%s.log", timebuffer);

	if (!DirExists("materials/resizablespraysv3", false))
		CreateDirectory("materials/resizablespraysv3", 511, false); // 511 decimal = 755 octal

	for (int c = 1; c <= MaxClients; c++) {
		if (IsValidClient(c)) {
			OnClientConnected(c);
			OnClientPostAdminCheck(c);
		}
	}
}

public void OnMapStart()
{
	g_mapMaterials = new StringMap();
	g_SprayQueue = new ArrayList(sizeof(Spray));
}

public Action PlayerSprayReal(const char[] szTempEntName, const int[] arrClients, int iClientCount, float flDelay) {
	int client = TE_ReadNum("m_nPlayer");
	if (IsValidClient(client))
		TE_ReadVector("m_vecOrigin", g_Players[client].fRealSprayLastPosition);
}

public void OnDownloadSuccess(int iClient, const char[] filename)
{
	Material material;
	bool isSprayMaterial = g_mapMaterials.GetArray(filename, material, sizeof(material));

	if (!isSprayMaterial) {
		if (StrEqual(filename[strlen(filename)-4], ".dat") && iClient > 0) {
			g_Players[iClient].DatQueue.GetValue(filename, g_bBuffer);
			PlaceRealSprays();
			g_Players[iClient].DatQueue.Remove(filename);
			LogToFile(g_strLogFile, "%N received .dat file %s (%d left in queue).", iClient, filename, g_Players[iClient].DatQueue.Size);
		}
		return;
	}

	if (iClient > 0) {
		LogToFile(g_strLogFile, "%N downloaded file '%s'", iClient, filename);
		material.iClientsFailure[iClient] = 0;
		material.iClientsSuccess[iClient] = GetClientUserId(iClient);
		g_mapMaterials.SetArray(filename, material, sizeof(material));
		return;
	}

	material.iReady = 2;
	g_mapMaterials.SetArray(filename, material, sizeof(material));
	LogToFile(g_strLogFile, "All players downloaded file '%s'", filename);
}

// TODO: Take better action on download failure, if necessary
public void OnDownloadFailure(int iClient, const char[] filename)
{
	if (iClient > 0) {
		if (IsValidClient(iClient)) {
			LogToFile(g_strLogFile, "Client %N did not download file '%s'", iClient, filename);
		}
		return;
	}

	LogToFile(g_strLogFile, "Error adding '%s' to download queue", filename);
}

// We're hijacking the standard spray-sending procedure so we can track
// progress of the .dat downloads
public Action OnFileSend(int client, const char[] sFile)
{
	char downloadDir[PLATFORM_MAX_PATH];
	Format(downloadDir, sizeof(downloadDir), "download/%s", sFile);

	// Not a .dat file, could be anything.
	if (!StrEqual(downloadDir[strlen(downloadDir)-4], ".dat")) {
		return Plugin_Continue;
	}

	// We call AddLateDownload at the end, which immediately calls SendFile again
	// File is already in the queue, so don't worry about it
	if (g_Players[client].DatQueue.GetValue(sFile, g_bBuffer)) {
		return Plugin_Continue;
	}

	// We could let the plugin continue here, but in this case we'll just get
	// CreateFragmentsFromFile: 'filename' doesn't exist
	// so we might as well stop now.
	if (!FileExists(downloadDir)) {
		PrintToServer("OnFileSend(%N): %s doesn't exist", client, downloadDir);
		return Plugin_Handled;
	}

	g_Players[client].DatQueue.SetValue(sFile, true);
	LogToFile(g_strLogFile, "OnFileSend: sending %s to %N (%d in queue)", sFile, client, g_Players[client].DatQueue.Size);
	AddLateDownload(sFile, false, client, true);

	return Plugin_Handled;
}

public void OnClientDisconnect(int client)
{
	ResetSprayInfo(client);
}

// Server will send files to clients BEFORE they have fully connected,
// so we need to initialize the .dat queue as soon as we can.
public void OnClientConnected(int client)
{
	CloseHandle(g_Players[client].DatQueue);
	g_Players[client].DatQueue = new StringMap();
}

public void OnClientPostAdminCheck(int client)
{
	ResetSprayInfo(client);

	// TODO: Is checking for both "" and NULL_STRING really necessary?
	if ((!cv_bEnabled.BoolValue) || StrEqual(g_Players[client].sSprayFile, "") || StrEqual(g_Players[client].sSprayFile, NULL_STRING))
		return;

	PrintToChat(client, "[SM] Preparing your spray for resizing...");

	CreateTimer(1.0, Timer_CheckIfSprayIsReady, client, TIMER_REPEAT);
}

public void ResetSprayInfo(int client)
{
	g_Players[client].bIsReadyToSpray = false;
	g_Players[client].bSprayHasBeenProcessed = false;
	g_Players[client].iSprayHeight = 0;
	g_Players[client].fScale = 1.0;
	g_Players[client].fLastSprayed = 0.0;
	g_Players[client].fRealSprayLastPosition[0] = -16384.0;
	g_Players[client].fRealSprayLastPosition[1] = -16384.0;
	g_Players[client].fRealSprayLastPosition[2] = -16384.0;

	// TODO: Compiler won't accept sizeof(g_Players[client].sSprayFile)
	if (IsValidClient(client)) {
		GetPlayerDecalFile(client, g_Players[client].sSprayFile, 12);
		GetPlayerSprayFilePath(client, g_Players[client].sSprayFilePath, PLATFORM_MAX_PATH);
	} else {
		g_Players[client].sSprayFile = "";
		g_Players[client].sSprayFilePath = "";
	}
}

public Action Timer_CheckIfSprayIsReady(Handle timer, int client)
{
	// TODO: Fix the odd structure regarding int test
	int test;
	if (!IsValidClient(client))
		return Plugin_Continue;

	if (g_Players[client].bSprayHasBeenProcessed && !g_Players[client].bIsReadyToSpray) {
		g_Players[client].bIsReadyToSpray = true;
		PrintToChat(client, "[SM] Your spray is ready! Type /spray %d to make big sprays.", RoundToZero(cv_fMaxSprayScale.FloatValue));
		return Plugin_Stop;
	} else {
		if (!g_Players[client].bSprayHasBeenProcessed) {
			test = ForceDownloadPlayerSprayFile(client);
			if (test == -1) {
				LogToFile(g_strLogFile, "Killing timer for %N", client);
				return Plugin_Stop;
			}
		}
	}

	return Plugin_Continue;
}

public int ForceDownloadPlayerSprayFile(int client)
{
	int dimensions[2] = {0, 0};

	if (!g_Players[client].bSprayHasBeenProcessed) {
		Handle vtfFile = OpenFile(g_Players[client].sSprayFilePath, "r", false);

		if (vtfFile == INVALID_HANDLE) {
			//LogToFile(g_strLogFile, "ForceDownloadPlayerSprayFile: File %s returned an invalid handle.", g_Players[client].sSprayFilePath);
			CloseHandle(vtfFile);
			return 0;
		}

		FileSeek(vtfFile, 16, SEEK_SET);
		ReadFile(vtfFile, dimensions, 2, 2);
		g_Players[client].iSprayHeight = dimensions[1];

		CloseHandle(vtfFile);

		if (g_Players[client].iSprayHeight <= 0) {
			LogToFile(g_strLogFile, "%N's spray %s (%s) was %d px, this isn't right...", client, g_Players[client].sSprayFilePath, g_Players[client].sSprayFile, g_Players[client].iSprayHeight);
			return -1;
		}

		g_Players[client].bSprayHasBeenProcessed = true;
	}
	return 0;
}

void PlaceRealSprays()
{
	for (int i = 1; i <= MaxClients; i++) {
		TE_Start("Player Decal");
		TE_WriteVector("m_vecOrigin", g_Players[i].fRealSprayLastPosition);
		TE_WriteNum("m_nEntity", 0);
		TE_WriteNum("m_nPlayer", i);
		TE_SendToAll();
	}
}

/*
	Handles the !spray and !bspray commands
	@param ID of client, will use their spray's unique filename
	@param number of args
*/
public Action Command_Spray(int client, int args)
{
	float scaleReal;
	char arg0[64]; GetCmdArg(0, arg0, sizeof(arg0));
	char arg1[64]; GetCmdArg(1, arg1, sizeof(arg1));
	char arg2[64]; GetCmdArg(2, arg2, sizeof(arg2));

	Spray spray;
	spray.iSprayer = client;
	spray.iClient = client;

	if (!IsValidClient(client))
		return Plugin_Handled;

	if (!cv_bEnabled.BoolValue)
		return Plugin_Handled;

	if (GetGameTime() - g_Players[client].fLastSprayed < cv_fDecalFrequency.FloatValue && !IsAdmin(client))
		return Plugin_Handled;
	g_Players[client].fLastSprayed = GetGameTime();

	if (StrEqual(arg0, "sm_bspray") && IsAdmin(client))
		spray.iDecalType = 1;

	if (args > 0) {
		if (!IsAdmin(client) && (args > 1 || !StringToFloatEx(arg1, g_Players[client].fScale))) {
			ReplyToCommand(client, "Usage: %s [desired_scale]", arg0);
			return Plugin_Handled;
		}

		if (IsAdmin(client) && (args > 2 || !StringToFloatEx(arg1, g_Players[client].fScale))) {
			ReplyToCommand(client, "Usage: %s [desired_scale] [user]", arg0);
			return Plugin_Handled;
		}

		if (IsAdmin(client) && args == 2) {
			spray.iClient = FindTarget(client, arg2, true, true);
			if (spray.iClient == -1)
				return Plugin_Handled;

			if (!IsValidClient(spray.iClient)) {
				ReplyToCommand(client, "[SM] This client isn't in game yet! Please try again later.");
				return Plugin_Handled;
			}
		}
	}

	if (!g_Players[spray.iClient].bIsReadyToSpray) {
		ReplyToCommand(client, "[SM] We're still preparing this spray! Please try again later.");
		return Plugin_Handled;
	}

	scaleReal = GetRealSprayScale(client, spray.iClient, g_Players[client].fScale);

	PlaceRealSprays();
	CalculateSprayPosition(client, spray);

	if (spray.iEntity > -1) {
		LogToFile(g_strLogFile, "Command_Spray: %N is spraying %N's spray at %0.4f (%0.4f) scale, size %d", client, spray.iClient, g_Players[client].fScale, scaleReal, g_Players[client].iSprayHeight);
		int sprayIndex;
		if ((sprayIndex = WriteVMT(spray, scaleReal)) != -1)
			CreateTimer(0.0, Timer_PrecacheAndSprayDecal, sprayIndex, TIMER_REPEAT);

	} else {
		ReplyToCommand(client, "[SM] You are too far away from a valid surface to place a spray!");
	}

	return Plugin_Handled;
}

float GetRealSprayScale(int sprayer, int owner, float scale)
{
	if (!IsAdmin(sprayer) && scale > cv_fMaxSprayScale.FloatValue)
		scale = cv_fMaxSprayScale.FloatValue;

	if (FloatEqual(g_Players[sprayer].fScale, 0.0, 0.0001)) {
		scale = 1.0;
	}

	// We shouldn't be here if iSprayHeight is 0
	return scale * SPRAY_UNIT_DIMENSION_FLOAT / float(g_Players[owner].iSprayHeight);
}

/*
	Writes a VMT file to the server, then sends it to all available clients
	@param ID of client, will use their spray's unique filename
	@param scale of decal for generated material
	@param buffer for material name
*/
public int WriteVMT(Spray spray, float scaleReal)
{
	Material material;
	material.fScaleReal = scaleReal;

	char playerdecalfile[12];

	char data[512];
	char scaleString[16];
	char vmtFilename[128];

	GetPlayerDecalFile(spray.iClient, playerdecalfile, sizeof(playerdecalfile));

	Format(data, 512, g_vmtTemplate, playerdecalfile, scaleReal);

	// Get rid of the period in float representation. Source engine doesn't like
	// loading files with more than one . in the filename.
	Format(scaleString, 16, "%.4f", scaleReal); ReplaceString(scaleString, 16, ".", "-", false);

	Format(spray.sMaterialName, 64, "resizablespraysv3/%s_%s", playerdecalfile, scaleString);
	Format(vmtFilename, 128, "materials/%s.vmt", spray.sMaterialName);

	// Make new material if it doesn't exist
	if (!g_mapMaterials.GetArray(vmtFilename, material, sizeof(material))) {
		g_mapMaterials.SetArray(vmtFilename, material, sizeof(material));
	}

	// We've already processed this spray
	if (material.iReady) {
		spray.fSprayTime = GetGameTime();
		return g_SprayQueue.PushArray(spray);
	}

	if (!FileExists(vmtFilename, false)) {
		Handle vmt = OpenFile(vmtFilename, "w+", false);
		if (vmt != INVALID_HANDLE)
			WriteFileString(vmt, data, false);
		CloseHandle(vmt);
	}

	LogToFile(g_strLogFile, "Adding late download %s", vmtFilename);

	for (int c = 1; c <= MaxClients; c++) {
		if (IsValidClient(c)) {
			material.iClientsFailure[c] = GetClientUserId(c);
			if (g_Players[c].DatQueue.Size == 0)
				AddLateDownload(vmtFilename, false, c);
		}
	}
	material.iReady = 1;
	g_mapMaterials.SetArray(vmtFilename, material, sizeof(material));

	spray.fSprayTime = GetGameTime();
	return g_SprayQueue.PushArray(spray);
}

/*
	Precaches the freshly-generated VMT file
*/
public Action Timer_PrecacheAndSprayDecal(Handle timer, int sprayIndex)
{
	// this shouldn't be necessary but it is
	if (g_SprayQueue.Length < sprayIndex) {
		LogToFile(g_strLogFile, "ERROR: Spray queue length is %d but we tried to spray %d!", g_SprayQueue.Length, sprayIndex);
		return Plugin_Stop;
	}

	Material material;
	Spray spray;
	char vmtFilename[PLATFORM_MAX_PATH];

	g_SprayQueue.GetArray(sprayIndex, spray);

	Format(vmtFilename, 128, "materials/%s.vmt", spray.sMaterialName);

	if (!g_mapMaterials.GetArray(vmtFilename, material, sizeof(material)))
	{
		LogToFile(g_strLogFile, "############################");
		LogToFile(g_strLogFile, "%s not in global array!", vmtFilename);
		LogToFile(g_strLogFile, "############################");
	}

	float timeWaiting = GetGameTime() - spray.fSprayTime;

	if (!IsValidClient(spray.iClient)) {
		LogToFile(g_strLogFile, "Client %d is invalid! They most likely have left the server. Aborting spray operation.", spray.iClient);
		return Plugin_Stop;
	}

	if (material.iReady == 2 || (timeWaiting > cv_fSprayTimeout.FloatValue > 0.0)) {

		if (timeWaiting > cv_fSprayTimeout.FloatValue > 0.0) {
			LogToFile(g_strLogFile, "Timed out waiting for all clients to download %s, precaching material anyways.", vmtFilename);
			material.iReady = 2;
		}

		material.iPrecache = PrecacheDecal(spray.sMaterialName, false);
		g_mapMaterials.SetArray(vmtFilename, material, sizeof(material));

		PlaceSpray(spray);

		return Plugin_Stop;
	}

	return Plugin_Continue;
}

/*
	Calculates where a client is looking and what entity they're looking at
	@param client id
	@return entity client is looking at. 0 means worldspawn (non-entity brushes)
	@error -1 if entity is out of range
	Credit to SM Franug for the original code
	https://forums.alliedmods.net/showthread.php?p=2118030
*/
public void CalculateSprayPosition(int client, Spray spray)
{
	float fAngles[3];
	float fOrigin[3];
	float fVector[3];

	if (!IsValidClient(client) || !IsPlayerAlive(client)) {
		LogToFile(g_strLogFile, "CalculateSprayPosition: client %i is either invalid or dead", client);
		spray.iEntity = -1;
		return;
	}

	GetClientEyeAngles(client, fAngles);
	GetClientEyePosition(client, fOrigin);

	Handle hTrace = TR_TraceRayFilterEx(fOrigin, fAngles, MASK_SHOT, RayType_Infinite, TraceEntityFilterPlayer);
	if (TR_DidHit(hTrace))
		TR_GetEndPosition(spray.fPosition, hTrace);

	spray.iEntity = TR_GetEntityIndex(hTrace);
	spray.iHitbox = TR_GetHitBoxIndex(hTrace);

	CloseHandle(hTrace);

	MakeVectorFromPoints(spray.fPosition, fOrigin, fVector);

	if (GetVectorLength(fVector) > cv_fMaxSprayDistance.FloatValue > 0.0 && !IsAdmin(client)) {
		//LogToFile(g_strLogFile, "CalculateSprayPosition: %N is too far from a valid surface (%0.4f > %0.4f)", client, GetVectorLength(fVector), cv_fMaxSprayDistance.FloatValue);
		spray.iEntity = -1;
	}
}

/*
	Places a decal in the world after precaching
	@param client id
	@param precache ID of material to place
	@param entity to place decal on
	@param position to place decal
	@param type of decal to place. 0 is world decal, 1 is BSP decal
*/
public void PlaceSpray(Spray spray)
{
	Material material;
	char vmtFilename[PLATFORM_MAX_PATH];

	Format(vmtFilename, 128, "materials/%s.vmt", spray.sMaterialName);

	g_mapMaterials.GetArray(vmtFilename, material, sizeof(material));

	switch (spray.iDecalType) {
		case 0: {
			TE_Start("Entity Decal");
			TE_WriteVector("m_vecOrigin", spray.fPosition);
			TE_WriteVector("m_vecStart", spray.fPosition);
			TE_WriteNum("m_nEntity", spray.iEntity);
			TE_WriteNum("m_nHitbox", spray.iHitbox);
			TE_WriteNum("m_nIndex", material.iPrecache);
		}
		case 1: {
			TE_Start("BSP Decal");
			TE_WriteVector("m_vecOrigin", spray.fPosition);
			TE_WriteNum("m_nEntity", spray.iEntity);
			TE_WriteNum("m_nIndex", material.iPrecache);
		}
	}

	int[] targets = new int[MaxClients];
	int numTargets = 0;

	// Only include known successful downloads
	for (int c = 1; c <= MaxClients; c++) {
		if (IsValidClient(c) && material.iClientsSuccess[c] == GetClientUserId(c)) {
			targets[numTargets++] = c;
		}
	}

	TE_Send(targets, numTargets);

	EmitSoundToAll("player/sprayer.wav", spray.iSprayer, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 0.35);

	return;
}


public bool TraceEntityFilterPlayer(int iEntity, int iContentsMask)
{
	return iEntity > MaxClients;
}

/*
	Determines if client is actually ready and in game
	@param client id
	@param whether or not to consider bots as valid clients
	@return true if user is ready, false otherwise
*/
stock bool IsValidClient(int client, bool nobots = true)
{
	if (client <= 0 || client > MaxClients || !IsClientConnected(client) || (nobots && IsFakeClient(client)))
		return false;

	return IsClientInGame(client);
}

/*
	Determines if a client can bypass spray restrictions
	@param client id
	@return true if user is allowed to bypass restrictions, false otherwise
*/
stock bool IsAdmin(int client)
{
	char adminFlagsBuffer[16];
	cv_sAdminFlags.GetString(adminFlagsBuffer, sizeof(adminFlagsBuffer));

	return CheckCommandAccess(client, "", ReadFlagString(adminFlagsBuffer), false);
}

stock bool FloatEqual(float a, float b, float error) {
    return a - b < FloatAbs(error);
}

// Returns player spray save file into string buffer
// Return value depends on engine
stock void GetPlayerSprayFilePath(int client, char[] buffer, int length)
{
	char strGame[PLATFORM_MAX_PATH];
	char playerdecalfile[PLATFORM_MAX_PATH];

	GetGameFolderName(strGame, sizeof(strGame));
	GetPlayerDecalFile(client, playerdecalfile, sizeof(playerdecalfile));

	if (strcmp(strGame, "left4dead2") == 0)
		Format(buffer, length, "downloads/%s.dat", playerdecalfile);
	else
		Format(buffer, length, "download/user_custom/%c%c/%s.dat", playerdecalfile[0], playerdecalfile[1], playerdecalfile);
}
