/*  Picked apart from SM Franug's CSGO Sprays plugin
 *
 *  https://forums.alliedmods.net/showthread.php?p=2118030
 *
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
#include <filenetmessages>

#pragma newdecls required
#pragma semicolon 1

// TODO: move this to a separate file
char g_vmtTemplate[512] = "LightmappedGeneric\n\
{\n\
\t$basetexture \"temp/%s\"\n\
\t$vertexcolor 1\n\
\t$vertexalpha 1\n\
\t$translucent 1\n\
\t$decal 1\n\
\tdecalsecondpass 1\n\
\t$decalscale %.4f\n\
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
} ";

float g_fClientLastSprayed[MAXPLAYERS + 1];

ConVar cv_sAdminFlags;
ConVar cv_fSprayDelay;

ConVar cv_fMaxSprayScale;
ConVar cv_iMaxSprayDistance;
ConVar cv_fDecalFrequency;

public Plugin myinfo =
{
	name = "Resizable Sprays",
	author = "Sappykun",
	description = "Enhances default sprays to allow for scaling.",
	version = "0.0.4",
	url = ""
}

public void OnPluginStart()
{
	RegConsoleCmd("sm_spray", Command_Spray, "Places a repeatable, scalable version of your spray as a world decal.");
	RegConsoleCmd("sm_bspray", Command_Spray, "Places a repeatable, scalable version of your spray as a BSP decal.");

	cv_sAdminFlags = CreateConVar("rspr_adminflags", "b", "Admin flags required to bypass restrictions", FCVAR_NONE, false, 0.0, false, 0.0);
	cv_fSprayDelay = CreateConVar("rspr_delay", "0.5", "Time to give to send out a VMT file. Setting this too low\nwill cause material loading errors on clients.", FCVAR_NONE, true, 0.0, false, 0.0);

	cv_iMaxSprayDistance = CreateConVar("rspr_maxspraydistance", "128", "Max range for placing decals. 0 is infinite range", FCVAR_NONE, true, 0.0, false);
	cv_fMaxSprayScale = CreateConVar("rspr_maxsprayscale", "0.20", "Maximum scale for sprays. Actual size depends on dimensions of your spray.\nFor reference, a 512x512 spray at 0.25 scale will be 128x128\nhammer units tall, double that of a normal 64x64 spray.", FCVAR_NONE, true, 0.0, false, 0.0);
	cv_fDecalFrequency = CreateConVar("rspr_decalfrequency", "0.5", "Spray frequency for non-admins. 0 is no delay.", FCVAR_NONE, true, 0.0, false);

	AutoExecConfig(true, "resizablesprays");
}

public void OnClientConnected(int client)
{
	g_fClientLastSprayed[client] = 0.0;
}

public Action Command_Spray(int client, int args)
{
	float scale;
	float fClientEyeViewPoint[3];
	int iEntity;
	char materialName[32];
	int decalType = 0;

	if (!IsValidClient(client))
		return Plugin_Handled;

	if (GetGameTime() - g_fClientLastSprayed[client] < cv_fDecalFrequency.FloatValue && !IsAdmin(client))
		return Plugin_Handled;

	g_fClientLastSprayed[client] = GetGameTime();

	if (args > 0) {
		if (args != 1) {
			ReplyToCommand(client, "Usage: sm_spray [desired_scale]", args);
			return Plugin_Handled;
		}

		char arg1[64]; GetCmdArg(1, arg1, sizeof(arg1));
		scale = StringToFloat(arg1);

		if (scale > cv_fMaxSprayScale.FloatValue && !IsAdmin(client))
			scale = cv_fMaxSprayScale.FloatValue;
	}
	else {
		scale = cv_fMaxSprayScale.FloatValue;
	}

	char arg0[64]; GetCmdArg(0, arg0, sizeof(arg0));
	if (StrEqual(arg0, "sm_bspray") && IsAdmin(client))
		decalType = 1;

	iEntity = CalculateClientEyeViewPoint(client, fClientEyeViewPoint);

	if (iEntity > -1) {
		WriteVMT(client, scale, materialName, 32);

		// We need to give the players time to download the VMT before we precache it
		// TODO: Perform a more robust check. Might need to replace filenetmessages
		// with latedownloads
		DataPack pack;
		CreateDataTimer(cv_fSprayDelay.FloatValue, Timer_PrecacheAndSprayDecal, pack);
		pack.WriteCell(client);
		pack.WriteCell(iEntity);
		pack.WriteCell(fClientEyeViewPoint[0]);
		pack.WriteCell(fClientEyeViewPoint[1]);
		pack.WriteCell(fClientEyeViewPoint[2]);
		pack.WriteString(materialName);
		pack.WriteCell(decalType);
	}

	return Plugin_Handled;
}

/*
	Writes a VMT file to the server, then sends it to all available clients
	@param ID of client, will use their spray's unique filename
	@param scale of decal for generated material
	@param buffer for material name
*/
public void WriteVMT(int client, float scale, char[] buffer, int buffersize)
{
	char spray[12]; GetPlayerDecalFile(client, spray, sizeof(spray));

	char data[512]; Format(data, 512, g_vmtTemplate, spray, scale);

	// Get rid of the period in float representation. Source engine doesn't like
	// loading files with more than one . in the filename.
	char scaleString[16]; Format(scaleString, 16, "%.4f", scale); ReplaceString(scaleString, 16, ".", "-", false);

	Format(buffer, buffersize, "customsprays/%s_%s", spray, scaleString);
	char filename[128]; Format(filename, 128, "materials/%s.vmt", buffer);

	if (!FileExists(filename, false)) {
		File vmt = OpenFile(filename, "w+", false);
		if (vmt != null)
			WriteFileString(vmt, data, false);
		CloseHandle(vmt);
	}

	float empty[3] =  { 0.0, 0.0, 0.0 };

	// Get clients to download spray
	TE_Start("Player Decal");
	TE_WriteVector("m_vecOrigin", empty);
	TE_WriteNum("m_nEntity", 0);
	TE_WriteNum("m_nPlayer", client);
	TE_SendToAll();

	// Send file to client
	for (int c = 1; c <= MaxClients; c++) {
		if (IsValidClient(c)) {
			FNM_SendFile(c, filename);
		}
	}
}

public Action Timer_PrecacheAndSprayDecal(Handle timer, DataPack pack)
{
	int client;
	int iEntity;
	float fClientEyeViewPoint[3];
	char materialName[32];
	int decalType;

	pack.Reset();
	client = pack.ReadCell();
	iEntity = pack.ReadCell();
	fClientEyeViewPoint[0] = pack.ReadCell();
	fClientEyeViewPoint[1] = pack.ReadCell();
	fClientEyeViewPoint[2] = pack.ReadCell();
	pack.ReadString(materialName, sizeof(materialName));
	decalType = pack.ReadCell();

	int precacheId = PrecacheDecal(materialName, false);
	Spray(client, precacheId, iEntity, fClientEyeViewPoint, decalType);
}


public void Spray(int client, int precacheId, int iEntity, float fClientEyeViewPoint[3], int decalType)
{
	//char classname[64]; GetEdictClassname(iEntity, classname, sizeof(classname));
	//PrintToChatAll("Looking at entity %i with classname %s.", iEntity, classname);

	switch (decalType) {
		case 0: {
			TE_Start("World Decal");
			TE_WriteVector("m_vecOrigin", fClientEyeViewPoint);
			TE_WriteNum("m_nIndex", precacheId);
			TE_SendToAll();
		}
		case 1: {
			TE_Start("BSP Decal");
			TE_WriteVector("m_vecOrigin", fClientEyeViewPoint);
			TE_WriteNum("m_nEntity", iEntity);
			TE_WriteNum("m_nIndex", precacheId);
			TE_SendToAll();
		}
	}

	EmitSoundToAll("player/sprayer.wav", client, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 0.6);

	return;
}

public int CalculateClientEyeViewPoint(int client, float fClientEyeViewPoint[3])
{
	if (!IsValidClient(client) || !IsPlayerAlive(client))
		return false;

	int ret = GetPlayerEyeViewPoint(client, fClientEyeViewPoint);

	float fClientEyePosition[3];
	GetClientEyePosition(client, fClientEyePosition);

	float fVector[3];
	MakeVectorFromPoints(fClientEyeViewPoint, fClientEyePosition, fVector);

	if (GetVectorLength(fVector) > cv_iMaxSprayDistance.IntValue > 0 && !IsAdmin(client))
		return -1;

	return ret;
}

stock int GetPlayerEyeViewPoint(int iClient, float fPosition[3])
{
	float fAngles[3];
	GetClientEyeAngles(iClient, fAngles);

	float fOrigin[3];
	GetClientEyePosition(iClient, fOrigin);

	Handle hTrace = TR_TraceRayFilterEx(fOrigin, fAngles, MASK_SHOT, RayType_Infinite, TraceEntityFilterPlayer);
	if(TR_DidHit(hTrace))
		TR_GetEndPosition(fPosition, hTrace);

	int iEntity = TR_GetEntityIndex(hTrace);
	CloseHandle(hTrace);

	return iEntity;
}

public bool TraceEntityFilterPlayer(int iEntity, int iContentsMask)
{
	return iEntity > MaxClients;
}

stock bool IsValidClient(int client, bool nobots = true)
{
	if (client <= 0 || client > MaxClients || !IsClientConnected(client) || (nobots && IsFakeClient(client)))
	{
		return false;
	}
	return IsClientInGame(client);
}

stock bool IsAdmin(int client)
{
	char adminFlagsBuffer[16];
	cv_sAdminFlags.GetString(adminFlagsBuffer, sizeof(adminFlagsBuffer));

	return CheckCommandAccess(client, "", ReadFlagString(adminFlagsBuffer), false);
}
