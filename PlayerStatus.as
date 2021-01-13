void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

array<float> last_player_use; // last time playerUse function was called for player (no calls = packet loss or not connected)
array<EHandle> loading_sprites;
array<RenderInfo> render_info;
array<int> lag_state; // 1 = message sent that the player crashed, -1 = joining the game

float disconnect_message_time = 3.0f; // player considered disconnected after this many seconds

class RenderInfo {
	int rendermode;
	int renderfx;
	float renderamt;
}

string loading_spr = "sprites/loading.spr";

void PluginInit()  {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "https://github.com/wootguy" );
	
	g_Hooks.RegisterHook( Hooks::Player::ClientPutInServer, @ClientJoin );	
	g_Hooks.RegisterHook( Hooks::Player::PlayerPostThink, @PlayerPostThink );
	
	last_player_use.resize(33);
	loading_sprites.resize(33);
	render_info.resize(33);
	lag_state.resize(33);
	
	g_Scheduler.SetInterval("check_for_crashed_players", 0.05f, -1);
}

void MapInit() {
	g_Game.PrecacheModel(loading_spr);
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
			if (lag_state[i] == 1) {
				lag_state[i] = 0;
			}
			continue;
		}
		
		float lastPacket = g_Engine.time - last_player_use[i];
		
		bool isLagging = lastPacket > 0.5f || lag_state[i] == -1;
		
		if (lastPacket > disconnect_message_time) {
			if (lag_state[i] == 0) {
				lag_state[i] = 1;
				g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " lost connection to the server\n");
			}
		} else {
			
		}
		
		if (isLagging) {
			Vector spritePos = plr.pev.origin + Vector(0,0,44);
		
			if (loading_sprites[i].IsValid()) {
				CBaseEntity@ loadSprite = loading_sprites[i];
				loadSprite.pev.origin = spritePos;
				loadSprite.pev.frame = (loadSprite.pev.frame + 1) % 12;
			} else {
				dictionary keys;
				keys["origin"] = spritePos.ToString();
				keys["model"] = loading_spr;
				keys["rendermode"] = "2";
				keys["renderamt"] = "255";
				keys["framerate"] = "0";
				keys["scale"] = "0.15";
				keys["spawnflags"] = "1";
				CBaseEntity@ loadSprite = g_EntityFuncs.CreateEntity("env_sprite", keys, true);
				loading_sprites[i] = EHandle(loadSprite);
				
				// save old render info
				RenderInfo info;
				info.rendermode = plr.pev.rendermode;
				info.renderamt = plr.pev.renderamt;
				info.renderfx = plr.pev.renderfx;
				render_info[i] = info;
				
				plr.pev.rendermode = 2;
				plr.pev.renderamt = 144; // min amt that doesn't dip below 128 when fading (which causes rendering errors on some models)
				plr.pev.renderfx = 2;
			}
		} else {
			if (loading_sprites[i].IsValid()) {
				g_EntityFuncs.Remove(loading_sprites[i]);
				plr.pev.rendermode = render_info[i].rendermode;
				plr.pev.renderamt = render_info[i].renderamt;
				plr.pev.renderfx = render_info[i].renderfx;
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
			g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " fully loaded into the game after " + loadTime + " seconds\n");
			lag_state[plr.entindex()] = 0;
			return;
		}
	}
	
	println("new joiner loading in: " + plr.pev.netname + " (ping " + iping + ", loss " + packetLoss + ")");
	
	g_Scheduler.SetTimeout("detect_when_loaded", 0.1f, h_plr, startTime, consecutivePings);
}

HookReturnCode ClientJoin(CBasePlayer@ plr)
{	
	bool isListenServerHost = g_PlayerFuncs.AdminLevel(plr) == ADMIN_OWNER && !g_EngineFuncs.IsDedicatedServer();
	
	if (!isListenServerHost) {
		detect_when_loaded(EHandle(plr), g_Engine.time, 0);
	}
	
	last_player_use[plr.entindex()] = 10;
	lag_state[plr.entindex()] = -1;
	
	return HOOK_CONTINUE;
}

HookReturnCode ClientLeave(CBasePlayer@ plr)
{
	println("PLAYER LEFT AAAAAAA " + plr.pev.netname);
	return HOOK_CONTINUE;
}

HookReturnCode PlayerPostThink(CBasePlayer@ plr) {

	if (lag_state[plr.entindex()] == 1) {
		lag_state[plr.entindex()] = 0;
		int dur = int(g_Engine.time - last_player_use[plr.entindex()] + 0.5f);
		string a_or_an = (dur == 8 || dur == 11) ? "an " : "a ";
		g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " recovered from " + a_or_an + dur + " second lag spike\n");
	}

	last_player_use[plr.entindex()] = g_Engine.time;
	
	return HOOK_CONTINUE;
}
