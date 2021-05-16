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
#include <menus>
#include <filenetmessages>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_NAME "Resizable Sprays"
#define PLUGIN_DESC "Extends default sprays to allow for scaling and spamming"
#define PLUGIN_AUTHOR "Sappykun"
#define PLUGIN_VERSION "2.0.0"
#define PLUGIN_URL "https://forums.alliedmods.net/showthread.php?t=332418"

// TODO: move this to a separate file
char g_vmtTemplate[512] = "%s\n\
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

enum struct Spray {
	int iPrecache;
	int iPreviewSprite;
	int iClient;
	int iEntity;
	int iHitbox;
	int iDecalType;
	int iPreviewMode;
	float fScale;
	float fLastSprayed;
	float fPosition[3];
	float fNormal[3];
	char sMaterialName[64];
}

Spray g_Spray[MAXPLAYERS + 1];

Menu g_MenuPreview = null;

ConVar cv_sAdminFlags;
ConVar cv_fSprayDelay;
ConVar cv_fMaxSprayScale;
ConVar cv_fMaxSprayDistance;
ConVar cv_fDecalFrequency;
ConVar cv_iPreviewUpdateFrequency;

char g_strLogFile[PLATFORM_MAX_PATH];

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
	RegConsoleCmd("sm_spraymenu", Command_SprayMenu, "Toggles spray preview mode.");

	CreateConVar("rspr_version", PLUGIN_VERSION, "Resizable Sprays version. Don't touch this.", FCVAR_NOTIFY|FCVAR_DONTRECORD|FCVAR_SPONLY);

	cv_sAdminFlags = CreateConVar("rspr_adminflags", "b", "Admin flags required to bypass restrictions", FCVAR_NONE, false, 0.0, false, 0.0);
	cv_fSprayDelay = CreateConVar("rspr_delay", "0.5", "Time to give to send out a VMT file. Setting this too low\nwill cause material loading errors on clients.", FCVAR_NONE, true, 0.0, false, 0.0);
	cv_fMaxSprayDistance = CreateConVar("rspr_maxspraydistance", "128.0", "Max range for placing decals. 0 is infinite range", FCVAR_NONE, true, 0.0, false);
	cv_fMaxSprayScale = CreateConVar("rspr_maxsprayscale", "0.20", "Maximum scale for sprays. Actual size depends on dimensions of your spray.\nFor reference, a 512x512 spray at 0.25 scale will be 128x128\nhammer units tall, double that of a normal 64x64 spray.", FCVAR_NONE, true, 0.0, false, 0.0);
	cv_fDecalFrequency = CreateConVar("rspr_decalfrequency", "0.5", "Spray frequency for non-admins. 0 is no delay.", FCVAR_NONE, true, 0.0, false);
	cv_iPreviewUpdateFrequency = CreateConVar("rspr_previewupdatefrequency", "5", "Update the spray preview every X game ticks. Raising this may decrease server load but makes the preview more choppy.", FCVAR_NONE, true, 0.0, false);

	AutoExecConfig(true, "resizablesprays");
	LoadTranslations("common.phrases");

	char timebuffer[32];
	FormatTime(timebuffer, sizeof(timebuffer), "%F", GetTime());
	BuildPath(Path_SM, g_strLogFile, sizeof(g_strLogFile), "logs/rspr_%s.log", timebuffer);

	for (int i = 0; i < sizeof(g_Spray); i++)
		g_Spray[i].iPreviewSprite = -1;
}

public void OnMapStart() {
	g_MenuPreview = BuildSprayPreviewMenu();
}

Menu BuildSprayPreviewMenu()
{
	Menu menu = new Menu(SprayMenuHandler);

	menu.SetTitle("Resizable Sprays preview menu");
	menu.AddItem("place", "Place spray");
	menu.AddItem("change", "Change spray");
	menu.AddItem("increasebig", "Increase scale +0.1");
	menu.AddItem("decreasebig", "Decrease scale +0.1");
	menu.AddItem("increasesmall", "Increase scale +0.01");
	menu.AddItem("decreasesmall", "Decrease scale +0.01");
	menu.ExitButton = true;

	return menu;
}

/*
	Resets decalfrequency timer when client joins
*/
public void OnClientConnected(int client)
{
	g_Spray[client].fLastSprayed = 0.0;
}

/*
	Handles the !spray and !bspray commands
	@param ID of client, will use their spray's unique filename
	@param number of args
*/
public Action Command_Spray(int client, int args)
{
	LogToFile(g_strLogFile, "Command_Spray: client %i is spraying", client);

	char arg0[64]; GetCmdArg(0, arg0, sizeof(arg0));
	char arg1[64]; GetCmdArg(1, arg1, sizeof(arg1));
	char arg2[64]; GetCmdArg(2, arg2, sizeof(arg2));

	if (!IsValidClient(client))
		return Plugin_Handled;

	if (GetGameTime() - g_Spray[client].fLastSprayed < cv_fDecalFrequency.FloatValue && !IsAdmin(client))
		return Plugin_Handled;
	g_Spray[client].fLastSprayed = GetGameTime();
	//g_Spray[client].iPreviewMode = 0;
	//KillSprite(client);

	if (StrEqual(arg0, "sm_bspray") && IsAdmin(client))
		g_Spray[client].iDecalType = 1;

	if (args > 0) {
		if (!IsAdmin(client) && (args > 1 || !StringToFloatEx(arg1, g_Spray[client].fScale))) {
			ReplyToCommand(client, "Usage: %s [desired_scale]", arg0);
			return Plugin_Handled;
		}

		if (IsAdmin(client) && (args > 2 || !StringToFloatEx(arg1, g_Spray[client].fScale))) {
			ReplyToCommand(client, "Usage: %s [desired_scale] [user]", arg0);
			return Plugin_Handled;
		}

		if (IsAdmin(client) && args == 2) {
			g_Spray[client].iClient = FindTarget(client, arg2, true, true);
			if (g_Spray[client].iClient == -1) {
				return Plugin_Handled;
			}
		}

		ClampSpraySize(client, 0.0);
	}

	if (g_Spray[client].fScale <= 0.0)
			g_Spray[client].fScale = cv_fMaxSprayScale.FloatValue;
	if (g_Spray[client].iClient <= 0)
			g_Spray[client].iClient = client;

	LogToFile(g_strLogFile, "Command_Spray: %N is spraying %N's spray at %0.4f scale", client, g_Spray[client].iClient, g_Spray[client].fScale);

	CalculateSprayPosition(client);

	if (g_Spray[client].iEntity > -1) {

		WriteVMT(client, false);

		// We need to give the players time to download the VMT before we precache it
		// TODO: Perform a more robust check. Might need to replace filenetmessages
		// with latedownloads
		CreateTimer(cv_fSprayDelay.FloatValue, Timer_PrecacheAndSprayDecal, client);
	}

	return Plugin_Handled;
}

void ClampSpraySize(int client, float add)
{
	g_Spray[client].fScale += add;

	if (!IsAdmin(client) && g_Spray[client].fScale > cv_fMaxSprayScale.FloatValue)
		g_Spray[client].fScale = cv_fMaxSprayScale.FloatValue;

	if (g_Spray[client].fScale < 0.0)
		g_Spray[client].fScale = 0.0;
}

public Action Command_SprayMenu(int client, int args)
{
	if (g_Spray[client].iPreviewMode > 0)
		return Plugin_Handled;

	g_Spray[client].iPreviewMode = 1;

	if (g_Spray[client].fScale <= 0.0)
			g_Spray[client].fScale = cv_fMaxSprayScale.FloatValue;
	if (g_Spray[client].iClient <= 0)
			g_Spray[client].iClient = client;

	WriteVMT(client, true);
	CreateTimer(cv_fSprayDelay.FloatValue, Timer_PrecacheDecalAndDisplayPreviewMenu, client);

	return Plugin_Handled;
}

public int SprayMenuHandler(Menu menu, MenuAction action, int client, int index)
{
    /* If an option was selected, tell the client about the item. */
    if (action == MenuAction_Select) {
        switch (index) {

	      	case 0: {
				WriteVMT(client, false);
				CreateTimer(cv_fSprayDelay.FloatValue, Timer_PrecacheAndSprayDecal, client);
				g_Spray[client].iPreviewMode = 0;
	     	}
	     	case 1: {
				//PrintToChat(client, "Changing spray");
	     	}
	      	case 2: {
	      		ClampSpraySize(client, 0.1);
	      		g_MenuPreview.Display(client, MENU_TIME_FOREVER);
	     	}
	      	case 3: {
	      		ClampSpraySize(client, -0.1);
	      		g_MenuPreview.Display(client, MENU_TIME_FOREVER);
	     	}
	      	case 4: {
	      		ClampSpraySize(client, 0.01);
	      		g_MenuPreview.Display(client, MENU_TIME_FOREVER);
	     	}
	     	case 5: {
	      		ClampSpraySize(client, -0.01);
	      		g_MenuPreview.Display(client, MENU_TIME_FOREVER);
	     	}
    	}
    }

    else if (action == MenuAction_Cancel)
    {
        g_Spray[client].iPreviewMode = 0;
    }
}

/*
	Writes a VMT file to the server, then sends it to all available clients
	@param ID of client, will use their spray's unique filename
	@param scale of decal for generated material
	@param buffer for material name
*/
public void WriteVMT(int client, bool preview)
{
	char previewSuffix[16] = "";
	char materialShader[32] = "LightmappedGeneric";

	if (preview) {
		previewSuffix = "_preview";
		materialShader = "UnlitGeneric";
	}

	char playerdecalfile[12]; GetPlayerDecalFile(g_Spray[client].iClient, playerdecalfile, sizeof(playerdecalfile));

	char data[512]; Format(data, 512, g_vmtTemplate, materialShader, playerdecalfile, g_Spray[client].fScale);

	// Get rid of the period in float representation. Source engine doesn't like
	// loading files with more than one . in the filename.
	char scaleString[16]; Format(scaleString, 16, "%.4f", g_Spray[client].fScale); ReplaceString(scaleString, 16, ".", "-", false);

	Format(g_Spray[client].sMaterialName, 64, "resizablesprays/%s_%s", playerdecalfile, scaleString);
	char filename[128]; Format(filename, 128, "materials/%s%s.vmt", g_Spray[client].sMaterialName, previewSuffix);

	if (!FileExists(filename, false)) {
		if (!DirExists("materials/resizablesprays", false))
			CreateDirectory("materials/resizablesprays", 511, false); // 511 decimal = 755 octal

		File vmt = OpenFile(filename, "w+", false);
		if (vmt != null)
			WriteFileString(vmt, data, false);
		CloseHandle(vmt);
	}

	float empty[3] =  { -16384.0, -16384.0, -16384.0 };

	// Get clients to download spray
	TE_Start("Player Decal");
	TE_WriteVector("m_vecOrigin", empty);
	TE_WriteNum("m_nEntity", 0);
	TE_WriteNum("m_nPlayer", g_Spray[client].iClient);
	TE_SendToAll();

	// Send file to client
	for (int c = 1; c <= MaxClients; c++) {
		if (IsValidClient(c)) {
			FNM_SendFile(c, filename);
		}
	}
}

/*
	Precaches the freshly-generated VMT file
*/
public Action Timer_PrecacheAndSprayDecal(Handle timer, int client)
{
	g_Spray[client].iPrecache = PrecacheDecal(g_Spray[client].sMaterialName, false);
	PlaceSpray(client);
}

public Action Timer_PrecacheDecalAndDisplayPreviewMenu(Handle timer, int client)
{
	char previewMaterialName[PLATFORM_MAX_PATH]; Format(previewMaterialName, PLATFORM_MAX_PATH, "%s_preview", g_Spray[client].sMaterialName);
	PrecacheDecal(previewMaterialName, false);
	g_Spray[client].iPreviewMode = 2;
	CreateSprite(client);
	g_MenuPreview.Display(client, MENU_TIME_FOREVER);
}

/*
	Calculates where a client is looking and what entity they're looking at
	@param client id
	@return entity client is looking at. 0 means worldspawn (non-entity brushes)
	@error -1 if entity is out of range
	Credit to SM Franug for the original code
	https://forums.alliedmods.net/showthread.php?p=2118030
*/
public void CalculateSprayPosition(int client)
{
	float fAngles[3];
	float fOrigin[3];
	float fVector[3];

	if (!IsValidClient(client) || !IsPlayerAlive(client)) {
		LogToFile(g_strLogFile, "CalculateSprayPosition: client %i is either invalid or dead", client);
		g_Spray[client].iEntity = -1;
		return;
	}

	GetClientEyeAngles(client, fAngles);
	GetClientEyePosition(client, fOrigin);

	Handle hTrace = TR_TraceRayFilterEx(fOrigin, fAngles, MASK_SHOT, RayType_Infinite, TraceEntityFilterPlayer);
	if (TR_DidHit(hTrace)) {
		TR_GetEndPosition(g_Spray[client].fPosition, hTrace);
		TR_GetPlaneNormal(hTrace, g_Spray[client].fNormal);
	}

	g_Spray[client].iEntity = TR_GetEntityIndex(hTrace);
	g_Spray[client].iHitbox = TR_GetHitBoxIndex(hTrace);

	CloseHandle(hTrace);

	MakeVectorFromPoints(g_Spray[client].fPosition, fOrigin, fVector);

	if (GetVectorLength(fVector) > cv_fMaxSprayDistance.FloatValue > 0.0 && !IsAdmin(client)) {
		LogToFile(g_strLogFile, "CalculateSprayPosition: %N is too far from a valid surface (%0.4f > %0.4f)", client, GetVectorLength(fVector), cv_fMaxSprayDistance.FloatValue);
		g_Spray[client].iEntity = -1;
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
public void PlaceSpray(int client)
{
	//char classname[64]; GetEdictClassname(iEntity, classname, sizeof(classname));
	//PrintToChatAll("Looking at entity %i with classname %s.", iEntity, classname);

	switch (g_Spray[client].iDecalType) {
		case 0: {
			TE_Start("Entity Decal");
			TE_WriteVector("m_vecOrigin", g_Spray[client].fPosition);
			TE_WriteVector("m_vecStart", g_Spray[client].fPosition);
			TE_WriteNum("m_nEntity", g_Spray[client].iEntity);
			TE_WriteNum("m_nHitbox", g_Spray[client].iHitbox);
			TE_WriteNum("m_nIndex", g_Spray[client].iPrecache);
			TE_SendToAll();
		}
		case 1: {
			TE_Start("BSP Decal");
			TE_WriteVector("m_vecOrigin", g_Spray[client].fPosition);
			TE_WriteNum("m_nEntity", g_Spray[client].iEntity);
			TE_WriteNum("m_nIndex", g_Spray[client].iPrecache);
			TE_SendToAll();
		}
	}

	EmitSoundToAll("player/sprayer.wav", client, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 0.6);

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
public bool IsAdmin(int client)
{
	char adminFlagsBuffer[16];
	cv_sAdminFlags.GetString(adminFlagsBuffer, sizeof(adminFlagsBuffer));

	return CheckCommandAccess(client, "", ReadFlagString(adminFlagsBuffer), false);
}


public void OnGameFrame() {
	if (GetGameTickCount() % cv_iPreviewUpdateFrequency.IntValue)
		return;

	for (int client = 1; client <= MAXPLAYERS; client++) {

		if (g_Spray[client].iPreviewSprite == 0 || !IsValidEdict(g_Spray[client].iPreviewSprite))
			return;

		if (g_Spray[client].iPreviewMode != 2) {
			if (g_Spray[client].iPreviewSprite > -1)
				KillSprite(client);
			return;
		}

		CalculateSprayPosition(client);
		MoveSprite(client);
	}
}

void CreateSprite(int client)
{
	int sprite = CreateEntityByName("env_sprite_oriented");
	if (IsValidEdict(sprite)) {
		char StrEntityName[64]; Format(StrEntityName, sizeof(StrEntityName), "env_sprite_oriented_%i", sprite);
		char strMaterialName[128]; Format(strMaterialName, sizeof(strMaterialName), "%s_preview.vmt", g_Spray[client].sMaterialName);

		DispatchKeyValue(sprite, "model", strMaterialName);
		DispatchKeyValue(client, "targetname", StrEntityName);
		DispatchKeyValue(sprite, "classname", "env_sprite_oriented");
		DispatchKeyValue(sprite, "renderamt", "127");
		DispatchKeyValue(sprite, "spawnflags", "1");
		DispatchKeyValue(sprite, "rendermode", "1");
		DispatchKeyValue(sprite, "rendercolor", "255 255 255");
		DispatchKeyValue(sprite, "framerate", "5");

		DispatchSpawn(sprite);

		g_Spray[client].iPreviewSprite = sprite;
	}
}

void MoveSprite(int client)
{
	float fAngles[3];
	float yaw = ArcTangent2(-g_Spray[client].fNormal[1], -g_Spray[client].fNormal[0]);

	fAngles[0] = g_Spray[client].fNormal[2] * 90.0; // pitch
	fAngles[1] = RadToDeg(yaw); // yaw
	fAngles[2] = 0.0; // roll, keep 0

	TeleportEntity(g_Spray[client].iPreviewSprite, g_Spray[client].fPosition, fAngles, NULL_VECTOR);
	DispatchKeyValueFloat(g_Spray[client].iPreviewSprite, "scale", g_Spray[client].fScale);
}

void KillSprite(int client)
{
	if (g_Spray[client].iPreviewSprite > 0 && IsValidEdict(g_Spray[client].iPreviewSprite))
		AcceptEntityInput(g_Spray[client].iPreviewSprite, "Kill");

	g_Spray[client].iPreviewSprite = -1;
}
