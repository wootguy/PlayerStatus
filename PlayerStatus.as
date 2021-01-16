void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

enum LAG_STATES {
	LAG_NONE,
	LAG_SEVERE_MSG,
	LAG_JOINING
}

array<float> last_player_use; // last time playerUse function was called for player (no calls = packet loss or not connected)
array<int> lag_spike_duration; // last time player was deemed not connected
array<EHandle> loading_sprites;
array<RenderInfo> render_info;
array<int> lag_state; // 1 = message sent that the player crashed, -1 = joining the game
array<bool> rendermode_applied; // 1 = message sent that the player crashed, -1 = joining the game
array<float> last_use_flow_start; // last time a consistent flow of PlayerThink calls was started

float disconnect_message_time = 4.0f; // player considered disconnected after this many seconds
float min_lag_detect = 0.3f; // minimum amount of a time a player needs to be disconnected before the icon shows

// when joining, you sometimes are loaded in for like a second, then the game freezes again
// this is how long to wait (seconds) until the player is consistently not lagging to consider
// the player fully loaded into the map
float min_flow_time = 1.5f;

class RenderInfo {
	int rendermode;
	int renderfx;
	float renderamt;
}

string loading_spr = "sprites/windows/hourglass.spr";
string warn_spr = "sprites/windows/xpwarn.spr";
string dial_spr = "sprites/windows/dial.spr";

string error_snd = "winxp/critical_stop.wav";
string startup_snd = "winxp/startup.wav";
string shutdown_snd = "winxp/shutdown.wav";
string exclaim_snd = "winxp/exclaim.wav";
string logon_snd = "winxp/logon.wav";
string popup_snd = "winxp/balloon.wav";
string dial_snd = "winxp/dial.wav";

float loading_spr_framerate = 10; // max of 15 fps before frames are dropped

void PluginInit()  {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "https://github.com/wootguy" );
	
	g_Hooks.RegisterHook( Hooks::Player::ClientPutInServer, @ClientJoin );
	g_Hooks.RegisterHook( Hooks::Player::ClientDisconnect, @ClientLeave );
	g_Hooks.RegisterHook( Hooks::Player::PlayerPostThink, @PlayerPostThink );
	
	last_player_use.resize(33);
	loading_sprites.resize(33);
	render_info.resize(33);
	lag_state.resize(33);
	rendermode_applied.resize(33);
	lag_spike_duration.resize(33);
	last_use_flow_start.resize(33);
	
	g_Scheduler.SetInterval("check_for_crashed_players", 0.1f, -1);
}

void MapInit() {
	g_Game.PrecacheModel(loading_spr);
	g_Game.PrecacheModel(warn_spr);
	g_Game.PrecacheModel(dial_spr);
	
	g_SoundSystem.PrecacheSound(error_snd);
	g_Game.PrecacheGeneric("sound/" + error_snd);
	
	g_SoundSystem.PrecacheSound(startup_snd);
	g_Game.PrecacheGeneric("sound/" + startup_snd);
	
	g_SoundSystem.PrecacheSound(shutdown_snd);
	g_Game.PrecacheGeneric("sound/" + shutdown_snd);
	
	g_SoundSystem.PrecacheSound(logon_snd);
	g_Game.PrecacheGeneric("sound/" + logon_snd);
	
	g_SoundSystem.PrecacheSound(exclaim_snd);
	g_Game.PrecacheGeneric("sound/" + exclaim_snd);
	
	g_SoundSystem.PrecacheSound(popup_snd);
	g_Game.PrecacheGeneric("sound/" + popup_snd);
	
	g_SoundSystem.PrecacheSound(dial_snd);
	g_Game.PrecacheGeneric("sound/" + dial_snd);
	
	rendermode_applied.resize(0);
	rendermode_applied.resize(33);
	last_use_flow_start.resize(0);
	last_use_flow_start.resize(33);
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
		
		bool isLagging = lastPacket > min_lag_detect || lag_state[i] == LAG_JOINING;
		
		if (lastPacket > disconnect_message_time) {
			if (lag_state[i] == LAG_NONE) {
				lag_state[i] = LAG_SEVERE_MSG;
				g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " lost connection to the server.\n");
				play_sound(plr, dial_snd, 0.5f, true);

				Vector spritePos = plr.pev.origin + Vector(0,0,44);
			
				g_EntityFuncs.Remove(loading_sprites[i]);
				
				dictionary keys;
				keys["origin"] = spritePos.ToString();
				keys["model"] = dial_spr;
				keys["rendermode"] = "2";
				keys["renderamt"] = "255";
				keys["framerate"] = "2";
				keys["scale"] =  "0.25";
				keys["spawnflags"] = "1";
				CBaseEntity@ newLoadSprite = g_EntityFuncs.CreateEntity("env_sprite", keys, true);
				loading_sprites[i] = EHandle(newLoadSprite);
			}
		}
		
		if (isLagging) {
			Vector spritePos = plr.pev.origin + Vector(0,0,44);
		
			if (loading_sprites[i].IsValid()) {
				CBaseEntity@ loadSprite = loading_sprites[i];
				loadSprite.pev.origin = spritePos;
			} else {
				dictionary keys;
				keys["origin"] = spritePos.ToString();
				keys["model"] = lag_state[i] == LAG_JOINING ? loading_spr : warn_spr;
				keys["rendermode"] = "2";
				keys["renderamt"] = "255";
				keys["framerate"] = "" + loading_spr_framerate;
				keys["scale"] = lag_state[i] == LAG_JOINING ? "0.15" : ".50";
				keys["spawnflags"] = "1";
				CBaseEntity@ loadSprite = g_EntityFuncs.CreateEntity("env_sprite", keys, true);
				loading_sprites[i] = EHandle(loadSprite);
				
				if (!loading_sprites[i].IsValid()) {
					println("OMGGGGG WHYYYYYYYYYY AAAAAAAAAAAAAAAAAAAAAAA");
				}
				
				// TODO: Called twice before reverting rendermode somehow
				
				if (!rendermode_applied[i]) {
					// save old render info
					RenderInfo info;
					info.rendermode = plr.pev.rendermode;
					info.renderamt = plr.pev.renderamt;
					info.renderfx = plr.pev.renderfx;
					render_info[i] = info;
					
					plr.pev.rendermode = 2;
					plr.pev.renderamt = 144; // min amt that doesn't dip below 128 when fading (which causes rendering errors on some models)
					plr.pev.renderfx = 2;
					
					println("Applying ghost rendermode to " + plr.pev.netname);
					
					rendermode_applied[i] = true;
					
					if (lag_state[i] != LAG_JOINING)
						play_sound(plr, exclaim_snd, 0.3f);
				}
			}
		} else {
			if (lag_state[i] == LAG_SEVERE_MSG) {
				lag_state[i] = LAG_NONE;
				int dur = lag_spike_duration[i];
				string a_or_an = (dur == 8 || dur == 11) ? "an " : "a ";
				g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " recovered from " + a_or_an + dur + " second lag spike.\n");
			}
			
			if (rendermode_applied[i]) {
				play_sound(plr, popup_snd, 0.7f);
			}
		
			if (loading_sprites[i].IsValid()) {
				g_EntityFuncs.Remove(loading_sprites[i]);
				plr.pev.rendermode = render_info[i].rendermode;
				plr.pev.renderamt = render_info[i].renderamt;
				plr.pev.renderfx = render_info[i].renderfx;
				rendermode_applied[i] = false;
				println("Restored normal rendermode to " + plr.pev.netname);
			}
			
			lag_spike_duration[i] = -1;
		}
	}
}

void play_sound(CBaseEntity@ target, string snd, float vol = 1.0f, bool loop=false) {
	int pit = 100;
	int flags = loop ? int(SND_FORCE_LOOP) : 0;
	g_SoundSystem.PlaySound(target.edict(), CHAN_STATIC, snd, vol, 0.8f, flags, pit, 0, true, target.pev.origin);
}

float last_flow_time = 0;

void detect_when_loaded(EHandle h_plr, float startTime) {
	if (!h_plr.IsValid()) {
		return;
	}
	
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	
	if (plr is null or !plr.IsConnected()) {
		return;
	}
	
	
	int idx = plr.entindex();
	float last_use_delta = g_Engine.time - last_player_use[idx];
	float flow_time = g_Engine.time - last_use_flow_start[idx];
	println("LOADED? " + last_use_delta + " " + flow_time);
	if (last_use_delta < min_lag_detect && flow_time > min_flow_time) {
		int loadTime = int((g_Engine.time - startTime) + 0.5f - min_flow_time);		
		string plural = loadTime != 1 ? "s" : "";
		g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " has finished loading.\n");
		lag_state[idx] = LAG_NONE;
		return;
	}
	
	g_Scheduler.SetTimeout("detect_when_loaded", 0.1f, h_plr, startTime);
}

HookReturnCode ClientJoin(CBasePlayer@ plr)
{	
	bool isListenServerHost = g_PlayerFuncs.AdminLevel(plr) == ADMIN_OWNER && !g_EngineFuncs.IsDedicatedServer();
	
	if (!isListenServerHost) {
		detect_when_loaded(EHandle(plr), g_Engine.time);
	}
	
	last_player_use[plr.entindex()] = -10;
	lag_state[plr.entindex()] = LAG_JOINING;
	
	return HOOK_CONTINUE;
}

HookReturnCode ClientLeave(CBasePlayer@ plr)
{
	if (lag_state[plr.entindex()] != LAG_NONE) {
		play_sound(plr, error_snd);
		rendermode_applied[plr.entindex()] = false;
	}
	return HOOK_CONTINUE;
}

HookReturnCode PlayerPostThink(CBasePlayer@ plr)
{
	int idx = plr.entindex();
	if (lag_state[idx] == LAG_SEVERE_MSG) {
		if (lag_spike_duration[idx] == -1) {
			lag_spike_duration[idx] = int(g_Engine.time - last_player_use[plr.entindex()] + 0.5f);
		}
	}
		
	if (g_Engine.time - last_player_use[idx] > min_lag_detect) {
		last_use_flow_start[idx] = g_Engine.time;
		println("FLOW INTERUUPTED");
	}
		
	last_player_use[idx] = g_Engine.time;
	
	return HOOK_CONTINUE;
}
