// TODO:
// - connecting joining player is null
// - flashlight + vc should disable afk
// - recovered from a 0 second lag spike
// - still not enough time for loading somehow (redmarket)

void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

enum LAG_STATES {
	LAG_NONE,
	LAG_SEVERE_MSG,
	LAG_JOINING
}

class PlayerState {
	float last_use = 0; // last time playerUse function was called for player (no calls = packet loss or not connected)
	int lag_spike_duration = 0; // time since last player packet when state is LAG_SEVERE_MSG
	EHandle loading_sprite; // status shown above head
	EHandle afk_sprite;
	int lag_state = LAG_NONE;  // 1 = message sent that the player crashed, -1 = joining the game
	RenderInfo render_info; // for undoing the disconnected render model
	bool rendermode_applied = false; // prevent applying rendermode twice (breaking the undo method)
	float last_use_flow_start = 0; // last time a consistent flow of PlayerThink calls was started
	float connection_time = 0; // time the player first connected on this map (resets if client aborts connection)
	float last_not_afk = g_Engine.time; // last time player pressed any buttons or sent a chat message
	int last_button_state = 0;
	bool afk_message_sent = false; // true after min_afk_message_time
	int afk_count = 0; // number of times afk'd this map
	float total_afk = 0; // total time afk (minus the current afk session)
	
	float get_total_afk_time() {
		float total = total_afk;
		
		// don't count current current afk session unless icon is showing
		float afkTime = g_Engine.time - last_not_afk;
		if (afkTime > afk_tier[0]) {
			total += afkTime;
		}
		
		return total;
	}
}

array<PlayerState> g_player_states;

float disconnect_message_time = 4.0f; // player considered disconnected after this many seconds
float min_lag_detect = 0.3f; // minimum amount of a time a player needs to be disconnected before the icon shows

// this is how long to wait (seconds) until the player is consistently not lagging to consider
// the player fully loaded into the map, after they've entered the final loading phase (when sounds precache)
// sometimes it takes a while for the final loading phase to start, depending on the map and player ping and specs
float min_flow_time = 3.0f;


float dial_loop_dur = 26.0; // duration of the dialup sound loop


bool debug_mode = false;

// time in seconds for different levels of afk
array<int> afk_tier = {
	30,    // cyan (min time)
	60,    // green (message sent)	
	60*5,  // yellow
	60*10, // orange
	60*30, // red
	60*60, // purple
};

class RenderInfo {
	int rendermode;
	int renderfx;
	float renderamt;
}

string loading_spr = "sprites/windows/hourglass.spr";
string warn_spr = "sprites/windows/xpwarn.spr";
string dial_spr = "sprites/windows/dial.spr";
string afk_spr = "sprites/zzz.spr";

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
	
	g_Hooks.RegisterHook(Hooks::Player::ClientConnected, @ClientConnect);
	g_Hooks.RegisterHook( Hooks::Player::ClientPutInServer, @ClientJoin );
	g_Hooks.RegisterHook( Hooks::Player::ClientDisconnect, @ClientLeave );
	g_Hooks.RegisterHook( Hooks::Player::PlayerPostThink, @PlayerPostThink );
	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @ClientSay );
	
	g_player_states.resize(33);
	
	g_Scheduler.SetInterval("update_player_status", 0.1f, -1);
}

void MapInit() {
	g_Game.PrecacheModel(loading_spr);
	g_Game.PrecacheModel(warn_spr);
	g_Game.PrecacheModel(dial_spr);
	g_Game.PrecacheModel(afk_spr);
	
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
	
	g_player_states.resize(0);
	g_player_states.resize(33);
}

void MapActivate() {
	modify_spawn_points_for_loading_detection();
}

// Normally, this happens when a player joins the game, and it's easy to detect when a player is loaded:
//   1) Player connects and spawns, but PlayerPostThink calls have not started yet.
//   2) PlayerPostThink calls start a few seconds later and their loading screen disappears.
//
// Weird stuff happens when laggy players load into a map with lots of custom content (e.g. io_v1 + 250ms ping):
//   1) Player connects and spawns
//   2) PlayerPostThink calls run normally for a few seconds, but the joining player still sees a loading screen.
//   3) Player starts precaching sounds or smth, and the PlayerPostThink calls stop.
//   4) Player fully loads in up to 60 seconds later, and the PlayerPostThink calls continue.
//
// At step 3, the player's "angles" variable is updated to match the spawn point, but only if the spawn point
// angles != (0,0,0). This works in survival mode too. By waiting for the angles to update, the plugin can then 
// wait for the PlayerPostThink calls to resume before saying "- Player has loaded". This prevents false positives
// at step 2, which may last several seconds, or less, or more. It depends on the map and the player's specs.
//
// So, in order to have reliable "is fully loaded" messages, all spawn points need to use non-default angles keys
void modify_spawn_points_for_loading_detection() {
	int updateCount = 0;
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "info_player_*");
		if (ent !is null) {
			if (ent.pev.angles.x == 0 && ent.pev.angles.y == 0 && ent.pev.angles.z == 0) {
				ent.pev.angles.y = 0.01f;
				updateCount++;
			}
		}
	} while (ent !is null);
	
	if (updateCount > 0) {
		println("PlayerStatus: updated " + updateCount + " spawn points to help with player load detection");
	}
}

string getUniqueId(CBasePlayer@ plr) {
	string steamid = g_EngineFuncs.GetPlayerAuthId( plr.edict() );

	if (steamid == 'STEAM_ID_LAN' or steamid == 'BOT') {
		return plr.pev.netname;
	}
	
	return steamid;
}

void update_player_status() {
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		PlayerState@ state = g_player_states[i];
		
		if (plr is null or !plr.IsConnected()) {
			g_EntityFuncs.Remove(state.loading_sprite);
			g_EntityFuncs.Remove(state.afk_sprite);
			if (state.lag_state != LAG_NONE) {
				state.lag_state = LAG_NONE;
			}
			continue;
		}
		
		if (debug_mode && plr.pev.netname != "w00tguy") {
			continue;
		}
		
		float lastPacket = g_Engine.time - state.last_use;
		
		bool isLagging = lastPacket > min_lag_detect || state.lag_state == LAG_JOINING;
		
		if (lastPacket > disconnect_message_time) {
			if (state.lag_state == LAG_NONE) {
				state.lag_state = LAG_SEVERE_MSG;
				g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "" + plr.pev.netname + " lost connection to the server.\n");
				play_sound(plr, dial_snd, 0.5f, dial_loop_dur);

				Vector spritePos = plr.pev.origin + Vector(0,0,44);
			
				g_EntityFuncs.Remove(state.loading_sprite);
				
				dictionary keys;
				keys["origin"] = spritePos.ToString();
				keys["model"] = dial_spr;
				keys["rendermode"] = "2";
				keys["renderamt"] = "255";
				keys["framerate"] = "2";
				keys["scale"] =  "0.25";
				keys["spawnflags"] = "1";
				CBaseEntity@ newLoadSprite = g_EntityFuncs.CreateEntity("env_sprite", keys, true);
				state.loading_sprite = EHandle(newLoadSprite);
			}
		}
		
		Vector spritePos = plr.pev.origin + Vector(0,0,44);
		
		if (isLagging)
		{
			g_EntityFuncs.Remove(state.afk_sprite);
			
			if (state.loading_sprite.IsValid()) {
				CBaseEntity@ loadSprite = state.loading_sprite;
				loadSprite.pev.origin = spritePos;
			} else {
				dictionary keys;
				keys["origin"] = spritePos.ToString();
				keys["model"] = state.lag_state == LAG_JOINING ? loading_spr : warn_spr;
				keys["rendermode"] = "2";
				keys["renderamt"] = "255";
				keys["framerate"] = "" + loading_spr_framerate;
				keys["scale"] = state.lag_state == LAG_JOINING ? "0.15" : ".50";
				keys["spawnflags"] = "1";
				CBaseEntity@ loadSprite = g_EntityFuncs.CreateEntity("env_sprite", keys, true);
				state.loading_sprite = EHandle(loadSprite);
				
				// TODO: Called twice before reverting rendermode somehow
				
				if (!state.rendermode_applied) {
					// save old render info
					RenderInfo info;
					info.rendermode = plr.pev.rendermode;
					info.renderamt = plr.pev.renderamt;
					info.renderfx = plr.pev.renderfx;
					state.render_info = info;
					
					plr.pev.rendermode = 2;
					plr.pev.renderamt = 144; // min amt that doesn't dip below 128 when fading (which causes rendering errors on some models)
					plr.pev.renderfx = 2;
					
					println("Applying ghost rendermode to " + plr.pev.netname);
					
					state.rendermode_applied = true;
					
					if (state.lag_state != LAG_JOINING)
						play_sound(plr, exclaim_snd, 0.3f);
				}
			}
		}
		else { // not lagging
			if (state.lag_state == LAG_SEVERE_MSG) {
				state.lag_state = LAG_NONE;
				int dur = state.lag_spike_duration;
				string a_or_an = (dur == 8 || dur == 11) ? "an " : "a ";
				g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "" + plr.pev.netname + " recovered from " + a_or_an + dur + " second lag spike.\n");
			}
			
			if (state.rendermode_applied) {
				play_sound(plr, popup_snd, 0.7f);
				plr.pev.rendermode = state.render_info.rendermode;
				plr.pev.renderamt = state.render_info.renderamt;
				plr.pev.renderfx = state.render_info.renderfx;
				state.rendermode_applied = false;
				println("Restored normal rendermode to " + plr.pev.netname);
			}
			
			g_EntityFuncs.Remove(state.loading_sprite);
			
			state.lag_spike_duration = -1;
			
			bool ok_to_afk = g_SurvivalMode.IsActive() && !plr.IsAlive();
			
			float afkTime = g_Engine.time - state.last_not_afk;
			if (!ok_to_afk && afkTime > afk_tier[0] && (plr.pev.effects & EF_NODRAW) == 0) {
				if (!state.afk_sprite.IsValid()) {
					dictionary keys;
					keys["origin"] = spritePos.ToString();
					keys["model"] = afk_spr;
					keys["rendermode"] = "2";
					keys["renderamt"] = "255";
					keys["rendercolor"] = "255 255 255";
					keys["framerate"] = "10";
					keys["scale"] = ".15";
					keys["spawnflags"] = "1";
					CBaseEntity@ spr = g_EntityFuncs.CreateEntity("env_sprite", keys, true);
					state.afk_sprite = EHandle(spr);
				}
			
				CBaseEntity@ afkSprite = state.afk_sprite;
				afkSprite.pev.origin = spritePos;
				
				Vector color = Vector(0, 255, 255);
				if (afkTime > afk_tier[5]) {
					color = Vector(128, 0, 255);
				} else if (afkTime > afk_tier[4]) {
					color = Vector(255, 0, 0);
				} else if (afkTime > afk_tier[3]) {
					color = Vector(255, 128, 0);
				} else if (afkTime > afk_tier[2]) {
					color = Vector(255, 255, 0);
				} else if (afkTime > afk_tier[1]) {
					color = Vector(0, 255, 0);
				} else {
					color = Vector(0, 255, 255);
				}
				
				afkSprite.pev.rendercolor = color;
			} else {
				g_EntityFuncs.Remove(state.afk_sprite);
			}
			
			if (!ok_to_afk && afkTime > afk_tier[1] && !state.afk_message_sent && !debug_mode) {
				state.afk_message_sent = true;
				state.afk_count++;
				
				if (state.afk_count > 2) {
					int c = state.afk_count;
					string suffix = "th";
					if (c % 10 == 3 && c != 13) {
						suffix = "rd";
					}
					if (c % 10 == 2 && c != 12) {
						suffix = "nd";
					}
					if (c % 10 == 1 && c != 11) {
						suffix = "st";
					}
					g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "" + plr.pev.netname + " is AFK for the " + state.afk_count + suffix + " time.\n");
				}
				else if (state.afk_count > 1) {
					
					g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "" + plr.pev.netname + " is AFK again.\n");
				} else {
					g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "" + plr.pev.netname + " is AFK.\n");
				}
			}
		}
	}
}

void play_sound(CBasePlayer@ target, string snd, float vol = 1.0f, float loopDelay=0) {	
	int pit = 100;
	g_SoundSystem.PlaySound(target.edict(), CHAN_VOICE, snd, vol, 0.8f, 0, pit, 0, true, target.pev.origin);
	
	if (loopDelay > 0) {
		g_Scheduler.SetTimeout("loop_sound", loopDelay, EHandle(target), snd, vol, loopDelay);
	}
}

// looped sounds sometimes get stuck looping forever, so manually check if the ent still exists
void loop_sound(EHandle h_target, string snd, float vol, float loopDelay) {
	CBasePlayer@ target = cast<CBasePlayer@>(h_target.GetEntity());
	if (target is null or !target.IsConnected() or g_player_states[target.entindex()].lag_state != LAG_SEVERE_MSG) {
		return;
	}
	
	play_sound(target, snd, vol, loopDelay);
}

void detect_when_loaded(EHandle h_plr, Vector lastAngles, int angleKeyUpdates) {
	if (!h_plr.IsValid()) {
		println("ABORT DETECT HANDLE NOT VALID");
		return;
	}
	
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	
	if (plr is null or !plr.IsConnected()) {
		println("ABORT DETECT PLR IS NULL OR NOT CONNECTED");
		return;
	}
	
	int idx = plr.entindex();
	
	// angles changing is the only thing visible to AS for detecting which stage of the loading process the player is in.
	// first angle change = spawn point angles
	// second angle change = reset back to 0,0,0 
	// third angle change = back to spawn angles, but only approximately. Sound precaching starts after this (lag spike)
	const int angleChangesForFinalLoadingPhase = 3;
	
	if (plr.pev.angles.x != lastAngles.x || plr.pev.angles.y != lastAngles.y || plr.pev.angles.z != lastAngles.z) {
		//println("ANGLES KEY UPDATEDDD " + plr.pev.angles.ToString());
		lastAngles = plr.pev.angles;
		angleKeyUpdates++;
		
		if (angleKeyUpdates == angleChangesForFinalLoadingPhase) {
			// reset the flow time to prevent message for loading in being sent too early.
			// Up until now, there's been a steady flow of PlayerPostThink calls. 
			// That is about to stop as the player starts precaching sounds.
			g_player_states[idx].last_use_flow_start = g_Engine.time;
			//println("BEGIN FINAL LOADING PHASE for " + plr.pev.netname);
		}
	}
	
	
	float last_use_delta = g_Engine.time - g_player_states[idx].last_use;
	float flow_time = g_Engine.time - g_player_states[idx].last_use_flow_start;
	bool isAlreadyPlaying = (plr.m_afButtonPressed | plr.m_afButtonReleased | plr.m_afButtonLast) != 0; // invalid until the final loading phase
	bool noMoreLagSpikes = last_use_delta < min_lag_detect && flow_time > min_flow_time;

	//println("Finished? " + last_use_delta + " " + flow_time + " " + isAlreadyPlaying + " " + noMoreLagSpikes);
	if (angleKeyUpdates >= angleChangesForFinalLoadingPhase && (noMoreLagSpikes || isAlreadyPlaying)) {
		int loadTime = int((g_Engine.time - g_player_states[idx].connection_time) + 0.5f - flow_time);		
		string plural = loadTime != 1 ? "s" : "";
		//g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " has finished loading (" + loadTime +" seconds).\n");
		g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " has finished loading.\n");
		g_player_states[idx].lag_state = LAG_NONE;
		g_player_states[idx].last_not_afk = g_Engine.time;
		//println("PLAYER HAS FINISHED LOADING");
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "ALL FINISHED YEAAAYY");
		return;
	}
	
	g_Scheduler.SetTimeout("detect_when_loaded", 0.1f, h_plr, lastAngles, angleKeyUpdates);
}


CBasePlayer@ getAnyPlayer() 
{
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "player");
		if (ent !is null) {
			CBasePlayer@ plr = cast<CBasePlayer@>(ent);
			return plr;
		}
	} while (ent !is null);
	return null;
}

void monitor_connect_edict(EHandle h_plr, string nick, float startTime) {
	CBaseEntity@ ent = h_plr;
	
	if (ent is null || string(ent.pev.netname) != nick) {
		CBasePlayer@ plr = getAnyPlayer();
		if (plr !is null) {
			int dur = int((g_Engine.time - startTime) + 0.5f);
			g_PlayerFuncs.SayTextAll(plr, "- " + nick + " canceled connecting after " + dur + " seconds.\n");
		}
		g_player_states[ent.entindex()].connection_time = 0;
		return;
	}
	
	if (g_player_states[ent.entindex()].last_use > 0) {
		// player has joined the game
		return;
	}
	
	g_Scheduler.SetTimeout("monitor_connect_edict", 0.1, h_plr, nick, startTime);
}

HookReturnCode ClientConnect(edict_t@ eEdict, const string &in sNick, const string &in sIp, bool &out bNoJoin, string &out sReason)
{
	CBasePlayer@ plr = getAnyPlayer();
	
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, sNick + " is connecting.\n");
	
	if (plr !is null) {
		//g_PlayerFuncs.SayTextAll(plr, "- " + sNick + " is connecting.\n");
		
		
		if (false) {
			CBaseEntity@ joiner = g_EntityFuncs.Instance(eEdict);
			g_player_states[joiner.entindex()].connection_time = g_Engine.time;
			g_Scheduler.SetTimeout("monitor_connect_edict", 0.1, EHandle(joiner), sNick, g_Engine.time);
		}			
	}
	return HOOK_CONTINUE;
}


HookReturnCode ClientJoin(CBasePlayer@ plr)
{	
	if (debug_mode && plr.pev.netname != "w00tguy") {
		// nothing
	} else {
		detect_when_loaded(EHandle(plr), Vector(0,0,0), 0);
	}
	
	int idx = plr.entindex();
	g_player_states[idx].last_use = 0;
	g_player_states[idx].last_use_flow_start = g_Engine.time;
	g_player_states[idx].lag_state = LAG_JOINING;
	g_player_states[idx].last_not_afk = g_Engine.time;
	
	return HOOK_CONTINUE;
}

HookReturnCode ClientLeave(CBasePlayer@ plr)
{
	int idx = plr.entindex();
	if (g_player_states[idx].lag_state != LAG_NONE) {
		play_sound(plr, error_snd);
	}
	
	g_player_states[idx].rendermode_applied = false;
	g_player_states[idx].last_use = 0;
	g_player_states[idx].connection_time = 0;
	
	return HOOK_CONTINUE;
}

string formatTime(float t, bool statsPage=false) {
	int rounded = int(t + 0.5f);
	
	int minutes = rounded / 60;
	int seconds = rounded % 60;
	
	if (statsPage) {
		string ss = "" + seconds;
		if (seconds < 10) {
			ss = "0" + ss;
		}
		return "" + minutes + ":" + ss + "";
	}
	if (minutes > 0) {
		string ss = "" + seconds;
		if (seconds < 10) {
			ss = "0" + ss;
		}
		return "" + minutes + ":" + ss + " minutes";
	} else {
		return "" + seconds + " seconds";
	}
}

void return_from_afk_message(CBasePlayer@ plr) {
	int idx = plr.entindex();
	float afkTime = g_Engine.time - g_player_states[idx].last_not_afk;
		
	bool ok_to_afk = g_SurvivalMode.IsActive() && !plr.IsAlive();
	
	if (afkTime > afk_tier[1])
		g_player_states[idx].total_afk += afkTime;
	
	if (!debug_mode) {
		if ((!ok_to_afk && afkTime > afk_tier[1]) || afkTime > afk_tier[2]) {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "" + plr.pev.netname + " was AFK for " + formatTime(afkTime) + ".\n");
		}
	}
}

HookReturnCode PlayerPostThink(CBasePlayer@ plr)
{
	int idx = plr.entindex();
	if (g_player_states[idx].lag_state == LAG_SEVERE_MSG) {
		if (g_player_states[idx].lag_spike_duration == -1) {
			g_player_states[idx].lag_spike_duration = int(g_Engine.time - g_player_states[idx].last_use + 0.5f);
		}
	}
		
	if (g_Engine.time - g_player_states[idx].last_use > min_lag_detect) {
		g_player_states[idx].last_use_flow_start = g_Engine.time;
	}
		
	g_player_states[idx].last_use = g_Engine.time;
	
	int buttons = plr.m_afButtonPressed & ~32768; // for some reason the scoreboard button is pressed on death/respawn	
	
	if (buttons != g_player_states[idx].last_button_state) {
		return_from_afk_message(plr);
	
		g_player_states[idx].last_not_afk = g_Engine.time;		
		g_player_states[idx].afk_message_sent = false;
	}
	
	g_player_states[idx].last_button_state = buttons;
	
	return HOOK_CONTINUE;
}

class AfkStat {
	string name;
	float time;
	PlayerState@ state;
}


// 0 = not handled, 1 = handled but show chat, 2 = handled and hide chat
int doCommand(CBasePlayer@ plr, const CCommand@ args, bool isConsoleCommand=false) {
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if ( args.ArgC() > 0 )
	{				
		if (isAdmin && args[0] == ".dstatus") {			
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "\n\nENGINE TIME: " + g_Engine.time);
			
			for ( int i = 1; i <= g_Engine.maxClients; i++ )
			{
				CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
				
				if (p is null or !p.IsConnected()) {
					continue;
				}
				PlayerState state = g_player_states[i];
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "\nSLOT " + i + ": " + p.pev.netname + "\n");
				//g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    last_use            = " + state.last_use + " (" + (g_Engine.time - state.last_use) + ")\n");
				//g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    last_use_flow_start = " + state.last_use_flow_start + " (" + (g_Engine.time - state.last_use_flow_start) + ")\n");
				//g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    rendermode_applied  = " + state.rendermode_applied + "\n");
				//g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    render_info         = " + state.render_info.rendermode + " " + state.render_info.renderfx + " " + state.render_info.renderamt + "\n");
				//g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    lag_state           = " + state.lag_state + "\n");
				//g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    loading_sprite      = " + (state.loading_sprite.IsValid() ? "true" : "false") + "\n");
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    afk_sprite          = " + (state.afk_sprite.IsValid() ? "true" : "false") + "\n");
				//g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    lag_spike_duration  = " + state.lag_spike_duration + "\n");
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    connection_time     = " + state.connection_time + "\n");
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    last_not_afk        = " + state.last_not_afk + "\n");
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    last_button_state   = " + state.last_button_state + "\n");
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    afk_message_sent    = " + state.afk_message_sent + "\n");
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    afk_count           = " + state.afk_count + "\n");
			}
			
			return 2;
		}
		
		if (isAdmin && args[0] == ".dreset") {			
			println("\n\nENGINE TIME: " + g_Engine.time);
			
			for ( int i = 1; i <= g_Engine.maxClients; i++ )
			{
				CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
				
				if (p is null or !p.IsConnected()) {
					continue;
				}
				
				PlayerState@ state = g_player_states[i];
				
				state.lag_state = LAG_NONE;
				
				//p.pev.rendermode = 0;
				//g_EntityFuncs.Remove(state.loading_sprite);
				//g_EntityFuncs.Remove(state.afk_sprite);
			}
			
			return 2;
		}
		
		if (args[0] == "afk?") {
			int totalAfk = 0;
			int totalPlayers = 0;
			
			array<string> afkers;
			
			for ( int i = 1; i <= g_Engine.maxClients; i++ )
			{
				CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
				
				if (p is null or !p.IsConnected()) {
					continue;
				}
				
				PlayerState@ state = g_player_states[i];
				
				float afkTime = g_Engine.time - state.last_not_afk;
				if (afkTime > afk_tier[0]) {
					totalAfk++;
					afkers.insertLast(p.pev.netname);
				}
				totalPlayers++;
			}
			
			int percent = int((float(totalAfk) / float(totalPlayers))*100);
			
			if (totalAfk == 0) {
				g_PlayerFuncs.SayTextAll(plr, "Nobody is AFK.\n");
			}
			else if (totalAfk == 1) {
				g_PlayerFuncs.SayTextAll(plr, afkers[0] + " is AFK.\n");
			}
			else if (totalAfk == 2) {
				string afkString = afkers[0] + " and " + afkers[1];
				g_PlayerFuncs.SayTextAll(plr, afkString + " are AFK.\n");
			}
			else if (totalAfk == 3) {
				string afkString = afkers[0] + ", " + afkers[1] + ", and " + afkers[2];
				g_PlayerFuncs.SayTextAll(plr, afkString + " are AFK (" + percent + "% of the server).\n");
			}
			else {
				g_PlayerFuncs.SayTextAll(plr, "" + totalAfk + " players are AFK (" + percent + "% of the server).\n");
			}
			
			return 1;
		}
		
		if (args[0] == ".listafk") {
			int totalAfk = 0;
			int totalPlayers = 0;
			
			array<AfkStat> afkStats;
			
			for ( int i = 1; i <= g_Engine.maxClients; i++ )
			{
				CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
				
				if (p is null or !p.IsConnected()) {
					continue;
				}
				
				PlayerState@ state = g_player_states[i];
				
				AfkStat stat;
				stat.name = p.pev.netname;
				stat.time = state.get_total_afk_time();
				@stat.state = @state;
				
				afkStats.insertLast(stat);
			}
			
			afkStats.sort(function(a,b) { return a.time > b.time; });
			
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nAFK times for this map (MINUTES:SECONDS)\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\n   Player Name              Total    AFK Now?\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '------------------------------------------------\n');
			
			for (uint i = 0; i < afkStats.size(); i++) {
				string pname = afkStats[i].name;
				
				while (pname.Length() < 24) {
					pname += " ";
				}
				if (pname.Length() > 24) {
					pname = pname.SubString(0, 21) + "...";
				}
				
				string idx = "" + (i+1);
				if (i+1 < 10) {
					idx = " " + idx;
				}
				
				string total = formatTime(afkStats[i].time, true) + "     ";
				string afkNow = (g_Engine.time - afkStats[i].state.last_not_afk) > afk_tier[0] ? "  Yes" : "  No";
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "" + idx + ") " + pname + " " + total + afkNow + '\n');
			}
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '------------------------------------------------\n\n');
			return 2;
		}
	}
	
	return 0;
}

HookReturnCode ClientSay( SayParameters@ pParams ) {
	CBasePlayer@ plr = pParams.GetPlayer();
	const CCommand@ args = pParams.GetArguments();	
	
	return_from_afk_message(plr);
	g_player_states[plr.entindex()].last_not_afk = g_Engine.time;
	
	int chatHandled = doCommand(plr, args, false);
	if (chatHandled > 0)
	{
		if (chatHandled == 2) {
			pParams.ShouldHide = true;
		}
		return HOOK_HANDLED;
	}
	
	return HOOK_CONTINUE;
}

CClientCommand _listafk("listafk", "AFK player commands", @consoleCmd );

void consoleCmd( const CCommand@ args ) {
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args, true);
}