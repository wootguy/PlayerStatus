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
}

array<PlayerState> g_player_states;

float disconnect_message_time = 3.0f; // player considered disconnected after this many seconds
float min_lag_detect = 0.3f; // minimum amount of a time a player needs to be disconnected before the icon shows

// when joining, you sometimes are loaded in for like a second, then the game freezes again
// this is how long to wait (seconds) until the player is consistently not lagging to consider
// the player fully loaded into the map
float min_flow_time = 1.5f;

// time in seconds for different levels of afk
array<int> afk_tier = {
	15,    // cyan (min time)
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
		
		if (plr is null or !plr.IsConnected()) {
			g_EntityFuncs.Remove(g_player_states[i].loading_sprite);
			g_EntityFuncs.Remove(g_player_states[i].afk_sprite);
			if (g_player_states[i].lag_state != LAG_NONE) {
				g_player_states[i].lag_state = LAG_NONE;
			}
			continue;
		}
		
		float lastPacket = g_Engine.time - g_player_states[i].last_use;
		
		bool isLagging = lastPacket > min_lag_detect || g_player_states[i].lag_state == LAG_JOINING;
		
		if (lastPacket > disconnect_message_time) {
			if (g_player_states[i].lag_state == LAG_NONE) {
				g_player_states[i].lag_state = LAG_SEVERE_MSG;
				g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " lost connection to the server.\n");
				play_sound(plr, dial_snd, 0.5f, true);

				Vector spritePos = plr.pev.origin + Vector(0,0,44);
			
				g_EntityFuncs.Remove(g_player_states[i].loading_sprite);
				
				dictionary keys;
				keys["origin"] = spritePos.ToString();
				keys["model"] = dial_spr;
				keys["rendermode"] = "2";
				keys["renderamt"] = "255";
				keys["framerate"] = "2";
				keys["scale"] =  "0.25";
				keys["spawnflags"] = "1";
				CBaseEntity@ newLoadSprite = g_EntityFuncs.CreateEntity("env_sprite", keys, true);
				g_player_states[i].loading_sprite = EHandle(newLoadSprite);
			}
		}
		
		Vector spritePos = plr.pev.origin + Vector(0,0,44);
		
		if (isLagging)
		{
			g_EntityFuncs.Remove(g_player_states[i].afk_sprite);
			
			if (g_player_states[i].loading_sprite.IsValid()) {
				CBaseEntity@ loadSprite = g_player_states[i].loading_sprite;
				loadSprite.pev.origin = spritePos;
			} else {
				dictionary keys;
				keys["origin"] = spritePos.ToString();
				keys["model"] = g_player_states[i].lag_state == LAG_JOINING ? loading_spr : warn_spr;
				keys["rendermode"] = "2";
				keys["renderamt"] = "255";
				keys["framerate"] = "" + loading_spr_framerate;
				keys["scale"] = g_player_states[i].lag_state == LAG_JOINING ? "0.15" : ".50";
				keys["spawnflags"] = "1";
				CBaseEntity@ loadSprite = g_EntityFuncs.CreateEntity("env_sprite", keys, true);
				g_player_states[i].loading_sprite = EHandle(loadSprite);
				
				// TODO: Called twice before reverting rendermode somehow
				
				if (!g_player_states[i].rendermode_applied) {
					// save old render info
					RenderInfo info;
					info.rendermode = plr.pev.rendermode;
					info.renderamt = plr.pev.renderamt;
					info.renderfx = plr.pev.renderfx;
					g_player_states[i].render_info = info;
					
					plr.pev.rendermode = 2;
					plr.pev.renderamt = 144; // min amt that doesn't dip below 128 when fading (which causes rendering errors on some models)
					plr.pev.renderfx = 2;
					
					println("Applying ghost rendermode to " + plr.pev.netname);
					
					g_player_states[i].rendermode_applied = true;
					
					if (g_player_states[i].lag_state != LAG_JOINING)
						play_sound(plr, exclaim_snd, 0.3f);
				}
			}
		}
		else { // not lagging
			if (g_player_states[i].lag_state == LAG_SEVERE_MSG) {
				g_player_states[i].lag_state = LAG_NONE;
				int dur = g_player_states[i].lag_spike_duration;
				string a_or_an = (dur == 8 || dur == 11) ? "an " : "a ";
				g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " recovered from " + a_or_an + dur + " second lag spike.\n");
			}
			
			if (g_player_states[i].rendermode_applied) {
				play_sound(plr, popup_snd, 0.7f);
			}
		
			if (g_player_states[i].loading_sprite.IsValid()) {
				g_EntityFuncs.Remove(g_player_states[i].loading_sprite);
				plr.pev.rendermode = g_player_states[i].render_info.rendermode;
				plr.pev.renderamt = g_player_states[i].render_info.renderamt;
				plr.pev.renderfx = g_player_states[i].render_info.renderfx;
				g_player_states[i].rendermode_applied = false;
				println("Restored normal rendermode to " + plr.pev.netname);
			}
			
			g_player_states[i].lag_spike_duration = -1;
			
			bool isGhost = plr.GetObserver() !is null && plr.GetObserver().IsObserver();
			
			float afkTime = g_Engine.time - g_player_states[i].last_not_afk;
			if (!isGhost && afkTime > afk_tier[0]) {
				if (!g_player_states[i].afk_sprite.IsValid()) {
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
					g_player_states[i].afk_sprite = EHandle(spr);
				}
			
				CBaseEntity@ afkSprite = g_player_states[i].afk_sprite;
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
				g_EntityFuncs.Remove(g_player_states[i].afk_sprite);
			}
			
			if (!isGhost && afkTime > afk_tier[1] && !g_player_states[i].afk_message_sent) {
				g_player_states[i].afk_message_sent = true;
				g_player_states[i].afk_count++;
				
				if (g_player_states[i].afk_count > 2) {
					int c = g_player_states[i].afk_count;
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
					g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " is AFK for the " + g_player_states[i].afk_count + suffix + " time\n");
				}
				else if (g_player_states[i].afk_count > 1) {
					g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " is AFK again\n");
				} else {
					g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " is AFK\n");
				}
			}
		}
	}
}

void play_sound(CBaseEntity@ target, string snd, float vol = 1.0f, bool loop=false) {
	int pit = 100;
	int flags = loop ? int(SND_FORCE_LOOP) : 0;
	g_SoundSystem.PlaySound(target.edict(), CHAN_STATIC, snd, vol, 0.8f, flags, pit, 0, true, target.pev.origin);
}

float last_flow_time = 0;

void detect_when_loaded(EHandle h_plr) {
	if (!h_plr.IsValid()) {
		return;
	}
	
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	
	if (plr is null or !plr.IsConnected()) {
		return;
	}
	
	
	int idx = plr.entindex();
	float last_use_delta = g_Engine.time - g_player_states[idx].last_use;
	float flow_time = g_Engine.time - g_player_states[idx].last_use_flow_start;
	bool isAlreadyPlaying = plr.pev.button != 0;
	bool noMoreLagSpikes = last_use_delta < min_lag_detect && flow_time > min_flow_time;

	if (noMoreLagSpikes || isAlreadyPlaying) {
		int loadTime = int((g_Engine.time - g_player_states[idx].connection_time) + 0.5f - flow_time);		
		string plural = loadTime != 1 ? "s" : "";
		g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " has finished loading (" + loadTime +" seconds).\n");
		g_player_states[idx].lag_state = LAG_NONE;
		g_player_states[idx].last_not_afk = g_Engine.time;
		return;
	}
	
	g_Scheduler.SetTimeout("detect_when_loaded", 0.1f, h_plr);
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
	println("Connect: " + sNick + " " + sIp + " " + bNoJoin + " " + sReason);
	if (bNoJoin) {
		CBasePlayer@ plr = getAnyPlayer();
		if (plr !is null) {
			g_PlayerFuncs.SayTextAll(plr, "- " + sNick + " is connecting.\n");
			//g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "- " + sNick + " is connecting.\n");
			CBaseEntity@ joiner = g_EntityFuncs.Instance(eEdict);
			
			g_player_states[joiner.entindex()].connection_time = g_Engine.time;
			g_Scheduler.SetTimeout("monitor_connect_edict", 0.1, EHandle(joiner), sNick, g_Engine.time);
		}
		
	}
	return HOOK_CONTINUE;
}


HookReturnCode ClientJoin(CBasePlayer@ plr)
{	
	detect_when_loaded(EHandle(plr));
	
	int idx = plr.entindex();
	g_player_states[plr.entindex()].last_use = -10;
	g_player_states[idx].lag_state = LAG_JOINING;
	
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

string formatTime(float t) {
	int rounded = int(t + 0.5f);
	
	int hours = rounded / (60*60);
	
	rounded -= hours * 60*60;
	
	int minutes = rounded / 60;
	int seconds = rounded % 60;

	
	if (hours > 0) {
		return "" + hours + " hours and " + minutes + " minutes";
	}
	else if (minutes > 0) {
		return "" + minutes + " minutes" + " and " + seconds + " seconds";
	} else {
		return "" + seconds + " seconds";
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
	
	int buttons = plr.m_afButtonPressed | plr.m_afButtonReleased;
	
	if (buttons != g_player_states[idx].last_button_state) {
		float afkTime = g_Engine.time - g_player_states[idx].last_not_afk;
		
		bool isGhost = plr.GetObserver() !is null && plr.GetObserver().IsObserver();
		
		if ((!isGhost && afkTime > afk_tier[1]) || afkTime > afk_tier[2]) {
			g_PlayerFuncs.SayTextAll(plr, "- " + plr.pev.netname + " was AFK for " + formatTime(afkTime) + ".\n");
		}
	
		g_player_states[idx].last_not_afk = g_Engine.time;		
		g_player_states[idx].afk_message_sent = false;
	}
	
	g_player_states[idx].last_button_state = buttons;
	
	return HOOK_CONTINUE;
}

bool doCommand(CBasePlayer@ plr, const CCommand@ args, bool isConsoleCommand=false) {
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if ( args.ArgC() > 0 )
	{				
		/*
		if (args[0] == "d") {
			g_PlayerFuncs.RespawnAllPlayers(true, true);
			return true;
		}
		*/
	}
	
	return false;
}

HookReturnCode ClientSay( SayParameters@ pParams ) {
	CBasePlayer@ plr = pParams.GetPlayer();
	const CCommand@ args = pParams.GetArguments();	
	
	g_player_states[plr.entindex()].last_not_afk = g_Engine.time;
	
	if (doCommand(plr, args, false))
	{
		pParams.ShouldHide = true;
		return HOOK_HANDLED;
	}
	
	return HOOK_CONTINUE;
}
