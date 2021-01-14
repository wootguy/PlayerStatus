void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

enum LAG_STATES {
	LAG_NONE,
	LAG_SEVERE_MSG,
	LAG_JOINING
}

array<float> last_player_use; // last time playerUse function was called for player (no calls = packet loss or not connected)
array<EHandle> loading_sprites;
array<RenderInfo> render_info;
array<int> lag_state; // 1 = message sent that the player crashed, -1 = joining the game
array<bool> rendermode_applied; // 1 = message sent that the player crashed, -1 = joining the game

float disconnect_message_time = 3.0f; // player considered disconnected after this many seconds

class RenderInfo {
	int rendermode;
	int renderfx;
	float renderamt;
}

string loading_spr = "sprites/hourglass_v3.spr";
float loading_spr_framerate = 10; // max of 15 fps before frames are dropped

void PluginInit()  {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "https://github.com/wootguy" );
	
	g_Hooks.RegisterHook( Hooks::Player::ClientPutInServer, @ClientJoin );	
	g_Hooks.RegisterHook( Hooks::Player::PlayerPostThink, @PlayerPostThink );
	
	last_player_use.resize(33);
	loading_sprites.resize(33);
	render_info.resize(33);
	lag_state.resize(33);
	rendermode_applied.resize(33);
	
	g_Scheduler.SetInterval("check_for_crashed_players", 0.1f, -1);
}

void MapInit() {
	g_Game.PrecacheModel(loading_spr);
	
	rendermode_applied.resize(0);
	rendermode_applied.resize(33);
}

string getUniqueId(CBasePlayer@ plr) {
	string steamid = g_EngineFuncs.GetPlayerAuthId( plr.edict() );

	if (steamid == 'STEAM_ID_LAN' or steamid == 'BOT') {
		return plr.pev.netname;
	}
	
	return steamid;
}

void check_for_crashed_players() {
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			g_EntityFuncs.Remove(loading_sprites[i]);
			if (lag_state[i] != LAG_NONE) {
				lag_state[i] = LAG_NONE;
			}
			continue;
		}
		
		float lastPacket = g_Engine.time - last_player_use[i];
		
		bool isLagging = lastPacket > 0.5f || lag_state[i] == LAG_JOINING;
		
		if (lastPacket > disconnect_message_time) {
			if (lag_state[i] == LAG_NONE) {
				lag_state[i] = LAG_SEVERE_MSG;
				g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " lost connection to the server.\n");
			}
		} else {
			
		}
		
		if (isLagging) {
			Vector spritePos = plr.pev.origin + Vector(0,0,44);
		
			if (loading_sprites[i].IsValid()) {
				CBaseEntity@ loadSprite = loading_sprites[i];
				loadSprite.pev.origin = spritePos;
			} else {
				dictionary keys;
				keys["origin"] = spritePos.ToString();
				keys["model"] = loading_spr;
				keys["rendermode"] = "2";
				keys["renderamt"] = "255";
				keys["framerate"] = "" + loading_spr_framerate;
				keys["scale"] = "0.15";
				keys["spawnflags"] = "1";
				CBaseEntity@ loadSprite = g_EntityFuncs.CreateEntity("env_sprite", keys, true);
				loading_sprites[i] = EHandle(loadSprite);
				
				if (!loading_sprites[i].IsValid()) {
					println("OMGGGGG WHYYYYYYYYYY AAAAAAAAAAAAAAAAAAAAAAA");
				}
				
				if (!rendermode_applied[i]) {
					// save old render info
					RenderInfo info;
					info.rendermode = plr.pev.rendermode;
					info.renderamt = plr.pev.renderamt;
					info.renderfx = plr.pev.renderfx;
					render_info[i] = info;
					
					// TODO: Called twice before reverting rendermode somehow
					
					plr.pev.rendermode = 2;
					plr.pev.renderamt = 144; // min amt that doesn't dip below 128 when fading (which causes rendering errors on some models)
					plr.pev.renderfx = 2;
					
					println("Applying ghost rendermode to " + plr.pev.netname);
					
					rendermode_applied[i] = true;
				}
				
			}
		} else {
			if (loading_sprites[i].IsValid()) {
				g_EntityFuncs.Remove(loading_sprites[i]);
				plr.pev.rendermode = render_info[i].rendermode;
				plr.pev.renderamt = render_info[i].renderamt;
				plr.pev.renderfx = render_info[i].renderfx;
				rendermode_applied[i] = false;
				println("Restored normal rendermode to " + plr.pev.netname);
			}
		}
	}
}


void detect_when_loaded(EHandle h_plr, float startTime, int consecutivePings) {
	if (!h_plr.IsValid()) {
		return;
	}
	
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	
	if (plr is null or !plr.IsConnected()) {
		println("Player lost connection");
		return;
	}
	
	int iping;
	int packetLoss;
	g_EngineFuncs.GetPlayerStats(plr.edict(), iping, packetLoss);
	
	if (iping > 0) {
		float lastPacketTime = g_Engine.time - last_player_use[plr.entindex()];
		if (lastPacketTime < 0.5f && ++consecutivePings >= 5) {
			int loadTime = int((g_Engine.time - startTime) + 0.5f);		
			string plural = loadTime != 1 ? "s" : "";
			g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " has finished loading.\n");
			lag_state[plr.entindex()] = LAG_NONE;
			return;
		}
	}
	
	//println("new joiner loading in: " + plr.pev.netname + " (ping " + iping + ", loss " + packetLoss + ")");
	
	g_Scheduler.SetTimeout("detect_when_loaded", 0.1f, h_plr, startTime, consecutivePings);
}

HookReturnCode ClientJoin(CBasePlayer@ plr)
{	
	bool isListenServerHost = g_PlayerFuncs.AdminLevel(plr) == ADMIN_OWNER && !g_EngineFuncs.IsDedicatedServer();
	
	if (!isListenServerHost) {
		detect_when_loaded(EHandle(plr), g_Engine.time, 0);
	}
	
	last_player_use[plr.entindex()] = -10;
	lag_state[plr.entindex()] = LAG_JOINING;
	
	return HOOK_CONTINUE;
}

HookReturnCode ClientLeave(CBasePlayer@ plr)
{
	return HOOK_CONTINUE;
}

HookReturnCode PlayerPostThink(CBasePlayer@ plr) {
	if (lag_state[plr.entindex()] == LAG_SEVERE_MSG) {
		lag_state[plr.entindex()] = LAG_NONE;
		int dur = int(g_Engine.time - last_player_use[plr.entindex()] + 0.5f);
		string a_or_an = (dur == 8 || dur == 11) ? "an " : "a ";
		g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " recovered from " + a_or_an + dur + " second lag spike.\n");
	}

	last_player_use[plr.entindex()] = g_Engine.time;
	
	return HOOK_CONTINUE;
}
