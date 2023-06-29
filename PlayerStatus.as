// TODO:
// - connecting joining player is null
// - flashlight + vc should disable afk
// - recovered from a 0 second lag spike
// - still not enough time for loading somehow (redmarket)
// - afk kick doesnt remove loading icon
// - afk sprite change size
// - show afk sprite for dead but not gibbed players

#include "inc/RelaySay"

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
	int lag_state = LAG_NONE;
	RenderInfo render_info; // for undoing the disconnected render model
	bool rendermode_applied = false; // prevent applying rendermode twice (breaking the undo method)
	float connection_time = 0; // time the player first connected on this map (resets if client aborts connection)
	float last_not_afk = g_Engine.time; // last time player pressed any buttons or sent a chat message
	int last_button_state = 0;
	bool afk_message_sent = false; // true after min_afk_message_time
	int afk_count = 0; // number of times afk'd this map
	float total_afk = 0; // total time afk (minus the current afk session)
	float fully_load_time = 0; // time the player last fully loaded into the server
	float lastPostThinkHook = 0; // last time the postThinkHook call ran for this player
	float lastPossess = 0;
	float lastRespawn = 0;
	bool wasAlive = false;
	
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
dictionary g_afk_stats; // maps steam id to afk time for players who leave the game

float disconnect_message_time = 4.0f; // player considered disconnected after this many seconds
float min_lag_detect = 0.3f; // minimum amount of a time a player needs to be disconnected before the icon shows

float suppress_lag_sounds_time = 10.0f; // time after joining to silence the lag sounds (can get spammy on map changes)

float dial_loop_dur = 26.0; // duration of the dialup sound loop
float last_afk_chat = -9999;
int afk_possess_alive_time = 20;

string ent_tname = "playerstatus_ent"; // for cleanup on plugin exit

array<string> possess_map_blacklist = {
	"fallguys_s2",
	"fallguys_s3",
	"sc5x_bonus",
	"hideandseek",
	"hide_in_grass_v2"
};

array<string> g_zzz_sprite_map_blacklist = {
	"sc5x_bonus",
	"hideandseek",
	"hideandrape_v2",
	"hide_in_grass_v2"
};

// time in seconds for different levels of afk
array<int> afk_tier = {
	30,    // cyan (min time)
	60,    // green (message sent)	
	60*2,  // yellow
	60*5, // orange
	60*10, // red
	60*20, // purple
};

class RenderInfo {
	int rendermode;
	int renderfx;
	float renderamt;
}

string loading_spr = "sprites/windows/hourglass.spr";
string warn_spr = "sprites/windows/xpwarn.spr";
string dial_spr = "sprites/windows/dial.spr";
string afk_spr = "sprites/zzz_v2.spr";

string error_snd = "winxp/critical_stop.wav";
string exclaim_snd = "winxp/exclaim.wav";
string popup_snd = "winxp/balloon.wav";
string dial_snd = "winxp/dial.wav";
string possess_snd = "debris/bustflesh1.wav";

float loading_spr_framerate = 10; // max of 15 fps before frames are dropped
int g_survival_afk_kill_countdown = 3;
int KILL_AFK_IN_SURVIVAL_DELAY = 3; // how long to wait before killing the last living players in survival mode, if they're all afk
const int POSSESS_COOLDOWN = 30;

CCVar@ cvar_afk_punish_time;

bool g_precached = false;
bool g_disable_zzz_sprite = false;

void PluginInit()  {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "https://github.com/wootguy" );
	
	g_Hooks.RegisterHook(Hooks::Player::ClientConnected, @ClientConnect);
	g_Hooks.RegisterHook( Hooks::Player::ClientPutInServer, @ClientJoin );
	g_Hooks.RegisterHook( Hooks::Player::ClientDisconnect, @ClientLeave );
	g_Hooks.RegisterHook( Hooks::Player::PlayerPreThink, @PlayerPreThink );
	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @ClientSay );
	g_Hooks.RegisterHook(Hooks::Game::MapChange, @MapChange);
	
	g_player_states.resize(33);
	
	g_Scheduler.SetInterval("update_player_status", 0.1f, -1);
	g_Scheduler.SetInterval("update_cross_plugin_state", 1.0f, -1);
	g_Scheduler.SetInterval("punish_afk_players", 1.0f, -1);
	
	@cvar_afk_punish_time = CCVar("afk_penalty_time", 60, "players afk for this long may be killed/kicked", ConCommandFlag::AdminOnly);
}

void PluginExit() {

	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByTargetname(ent, ent_tname); 
		if (ent !is null) {
			g_EntityFuncs.Remove(ent);
		}
	} while (ent !is null);
		
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		PlayerState@ state = g_player_states[i];
		
		if (state.rendermode_applied) {
			plr.pev.rendermode = state.render_info.rendermode;
			plr.pev.renderamt = state.render_info.renderamt;
			plr.pev.renderfx = state.render_info.renderfx;
		}
	}
}

void MapInit() {
	g_Game.PrecacheModel(loading_spr);
	g_Game.PrecacheModel(warn_spr);
	g_Game.PrecacheModel(dial_spr);
	g_Game.PrecacheModel(afk_spr);
	
	g_SoundSystem.PrecacheSound(error_snd);
	g_Game.PrecacheGeneric("sound/" + error_snd);
	
	g_SoundSystem.PrecacheSound(exclaim_snd);
	g_Game.PrecacheGeneric("sound/" + exclaim_snd);
	
	g_SoundSystem.PrecacheSound(popup_snd);
	g_Game.PrecacheGeneric("sound/" + popup_snd);
	
	g_SoundSystem.PrecacheSound(dial_snd);
	g_Game.PrecacheGeneric("sound/" + dial_snd);
	
	g_SoundSystem.PrecacheSound("thunder.wav");
	g_SoundSystem.PrecacheSound(possess_snd);
	
	g_player_states.resize(0);
	g_player_states.resize(33);
	
	last_afk_chat = -999;
	g_afk_stats.clear();
	g_precached = true;
	
	g_disable_zzz_sprite = g_zzz_sprite_map_blacklist.find(g_Engine.mapname) != -1;
}

HookReturnCode MapChange() {
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (p is null or !p.IsConnected()) {
			continue;
		}
		
		PlayerState@ state = g_player_states[i];
		string steamid = getUniqueId(p);
		int totalAfk = int(state.get_total_afk_time());
		
		if (g_afk_stats.exists(steamid)) {
			totalAfk += int(g_afk_stats[steamid]);
			g_afk_stats.delete(steamid);
		}
		
		string msg = "[AfkStats] " + steamid + " " + totalAfk + " " + p.pev.netname + "\n";
		g_Game.AlertMessage(at_console, msg);
		g_Game.AlertMessage(at_logged, msg);
	}
	
	array<string>@ afkKeys = g_afk_stats.getKeys();
	for (uint i = 0; i < afkKeys.length(); i++) {
		int afkTime = int(g_afk_stats[afkKeys[i]]);
		string msg = "[AfkStats] " + afkKeys[i] + " " + afkTime + " \\disconnected_player\\\n";
		g_Game.AlertMessage(at_console, msg);
		g_Game.AlertMessage(at_logged, msg);
	}
	
	return HOOK_CONTINUE;
}

string getUniqueId(CBasePlayer@ plr) {
	string steamid = g_EngineFuncs.GetPlayerAuthId( plr.edict() );

	if (steamid == 'STEAM_ID_LAN' or steamid == 'BOT') {
		return plr.pev.netname;
	}
	
	return steamid;
}

void update_player_status() {
	if (!g_precached || g_disable_zzz_sprite) {
		return;
	}

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
		
		if (plr.IsAlive() and !state.wasAlive) {
			state.lastRespawn = g_Engine.time;
		}
		state.wasAlive = plr.IsAlive();
		
		float lastPacket = g_Engine.time - state.last_use;
		
		bool isLagging = lastPacket > min_lag_detect || state.lag_state == LAG_JOINING;
		bool shouldSuppressLagsound = (g_Engine.time - state.fully_load_time) < suppress_lag_sounds_time;
		
		if (lastPacket > disconnect_message_time) {
			if (state.lag_state == LAG_NONE) {
				state.lag_state = LAG_SEVERE_MSG;
				g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "" + plr.pev.netname + " lost connection to the server.\n");
				if (!shouldSuppressLagsound)
					play_sound(plr, dial_snd, 0.3f, dial_loop_dur);

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
				keys["targetname"] = ent_tname;
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
				keys["targetname"] = ent_tname;
				CBaseEntity@ loadSprite = g_EntityFuncs.CreateEntity("env_sprite", keys, true);
				state.loading_sprite = EHandle(loadSprite);
				
				// TODO: Called twice before reverting rendermode somehow
				
				if (!state.rendermode_applied && state.lag_state != LAG_JOINING) {
					// save old render info
					RenderInfo info;
					info.rendermode = plr.pev.rendermode;
					info.renderamt = plr.pev.renderamt;
					info.renderfx = plr.pev.renderfx;
					state.render_info = info;
					
					plr.pev.rendermode = 2;
					plr.pev.renderamt = 144; // min amt that doesn't dip below 128 when fading (which causes rendering errors on some models)
					plr.pev.renderfx = 2;
					
					//println("Applying ghost rendermode to " + plr.pev.netname);
					
					state.rendermode_applied = true;
					
					if (state.lag_state != LAG_JOINING && !shouldSuppressLagsound)
						play_sound(plr, exclaim_snd, 0.2f);
				}
			}
		}
		else { // not lagging
			if (state.lag_state == LAG_SEVERE_MSG) {
				state.lag_state = LAG_NONE;
				int dur = state.lag_spike_duration;
				string a_or_an = (dur == 8 || dur == 11) ? "an " : "a ";
				g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "" + plr.pev.netname + " recovered from " + a_or_an + dur + " second lag spike.\n");
				g_Game.AlertMessage(at_console, "[LagLog] " + plr.pev.netname + " recovered from " + a_or_an + dur + " second lag spike.\n");
				g_Game.AlertMessage(at_logged, "[LagLog] " + plr.pev.netname + " recovered from " + a_or_an + dur + " second lag spike.\n");
			}
			
			if (state.rendermode_applied) {
				if (!shouldSuppressLagsound)
					play_sound(plr, popup_snd, 0.3f);
				plr.pev.rendermode = state.render_info.rendermode;
				plr.pev.renderamt = state.render_info.renderamt;
				plr.pev.renderfx = state.render_info.renderfx;
				state.rendermode_applied = false;
				//println("Restored normal rendermode to " + plr.pev.netname);
			}
			
			g_EntityFuncs.Remove(state.loading_sprite);
			
			state.lag_spike_duration = -1;
			
			bool ok_to_afk = g_SurvivalMode.IsActive() && !plr.IsAlive();
			
			float afkTime = g_Engine.time - state.last_not_afk;
			float gracePeriod = 2.0f; // allow other plugins to get the updated AFK state before the sprite is shown
			if (!ok_to_afk && afkTime > afk_tier[0]+gracePeriod && (plr.pev.effects & EF_NODRAW) == 0) {
				if (!state.afk_sprite.IsValid()) {
					dictionary keys;
					keys["model"] = afk_spr;
					keys["rendermode"] = "2";
					keys["renderamt"] = "255";
					keys["rendercolor"] = "255 255 255";
					keys["framerate"] = "10";
					keys["scale"] = ".15";
					keys["spawnflags"] = "1";
					keys["targetname"] = ent_tname;
					CBaseEntity@ spr = g_EntityFuncs.CreateEntity("env_sprite", keys, true);
					state.afk_sprite = EHandle(spr);
				}
			
				CBaseEntity@ afkSprite = state.afk_sprite;
				afkSprite.pev.movetype = MOVETYPE_FOLLOW;
				@afkSprite.pev.aiment = @plr.edict();
				
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
			
			if (!ok_to_afk && afkTime > afk_tier[1] && !state.afk_message_sent) {
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

void punish_afk_players() {
	if (cvar_afk_punish_time.GetInt() == 0 || !g_precached) {
		return;
	}

	int numAliveActive = 0;
	int numAliveAfk = 0;
	int numPlayers = 0;
	array<CBasePlayer@> afkPlayers;

	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		numPlayers += 1;
		
		PlayerState@ state = g_player_states[i];
		
		int afkTime = int(g_Engine.time - state.last_not_afk);
		bool isAfk = afkTime >= cvar_afk_punish_time.GetInt();
		
		if (isAfk) {
			if (plr.IsAlive()) {
				numAliveAfk += 1;
			}
			
			afkPlayers.insertLast(plr);
		} else if (plr.IsAlive()) {
			numAliveActive += 1;
		}
	}
	
	bool everyoneIsAfk = int(afkPlayers.size()) == numPlayers;
	bool lastLivingPlayersAreAfk = numAliveActive == 0 and numAliveAfk > 0;
	
	if (g_SurvivalMode.IsActive() and lastLivingPlayersAreAfk and !everyoneIsAfk) {
		// all living players are AFK
		if (g_survival_afk_kill_countdown == KILL_AFK_IN_SURVIVAL_DELAY) {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "All living players are AFK and will be killed in " + KILL_AFK_IN_SURVIVAL_DELAY + " seconds.\n");
		}
		
		g_survival_afk_kill_countdown -= 1;
	
		if (g_survival_afk_kill_countdown < 0) {
			g_survival_afk_kill_countdown = KILL_AFK_IN_SURVIVAL_DELAY;
			
			for (uint i = 0; i < afkPlayers.size(); i++) {
				CBasePlayer@ plr = afkPlayers[i];
				
				if (plr.IsAlive()) {
					TraceResult tr;
					g_Utility.TraceLine(plr.pev.origin, plr.pev.origin + Vector(0,0,1)*4096, ignore_monsters, plr.edict(), tr);
					
					NetworkMessage message(MSG_BROADCAST, NetworkMessages::SVC_TEMPENTITY, null);
						message.WriteByte(TE_BEAMPOINTS);
						message.WriteCoord(plr.pev.origin.x);
						message.WriteCoord(plr.pev.origin.y);
						message.WriteCoord(plr.pev.origin.z);
						message.WriteCoord(tr.vecEndPos.x);
						message.WriteCoord(tr.vecEndPos.y);
						message.WriteCoord(tr.vecEndPos.z);
						message.WriteShort(g_EngineFuncs.ModelIndex("sprites/laserbeam.spr"));
						message.WriteByte(0);
						message.WriteByte(1);
						message.WriteByte(2);
						message.WriteByte(16);
						message.WriteByte(64);
						message.WriteByte(175);
						message.WriteByte(215);
						message.WriteByte(255);
						message.WriteByte(255);
						message.WriteByte(0);
					message.End();
						
					NetworkMessage message2(MSG_BROADCAST, NetworkMessages::SVC_TEMPENTITY, null);
						message2.WriteByte(TE_DLIGHT);
						message2.WriteCoord(plr.pev.origin.x);
						message2.WriteCoord(plr.pev.origin.y);
						message2.WriteCoord(plr.pev.origin.z);
						message2.WriteByte(24);
						message2.WriteByte(175);
						message2.WriteByte(215);
						message2.WriteByte(255);
						message2.WriteByte(4);
						message2.WriteByte(88);
					message2.End();
					
					g_EntityFuncs.Remove(afkPlayers[i]);
				}
			}
			
			g_SoundSystem.PlaySound(g_EntityFuncs.Instance(0).edict(), CHAN_STATIC, "thunder.wav", 0.67f, 0.0f, 0, 100);
		}
	} else {
		if (g_survival_afk_kill_countdown != KILL_AFK_IN_SURVIVAL_DELAY) {
			string reason = "Someone woke up.";
			if (everyoneIsAfk) {
				reason = "Everyone is AFK now...";
			} else if (!g_SurvivalMode.IsActive()) {
				reason = "Survival mode was disabled.";
			}
			
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "AFK kill aborted. " + reason + "\n");
		}
		g_survival_afk_kill_countdown = KILL_AFK_IN_SURVIVAL_DELAY;
	}
	
	if (numPlayers == g_Engine.maxClients and afkPlayers.size() > 0) {
		// kick a random AFK player to make room for someone who wants to play
		CBasePlayer@ randomPlayer = afkPlayers[Math.RandomLong(0, afkPlayers.size()-1)];
		string pname = randomPlayer.pev.netname;
		
		g_EngineFuncs.ServerCommand("kick #" + g_EngineFuncs.GetPlayerUserId(randomPlayer.edict()) + " You were AFK on a full server.\n");
		g_EngineFuncs.ServerExecute();
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, pname + " was kicked for being AFK on a full server.\n" );
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

void update_cross_plugin_state() {
	if (g_Engine.time < 5.0f || !g_precached) {
		return;
	}

	CBaseEntity@ afkEnt = g_EntityFuncs.FindEntityByTargetname(null, "PlayerStatusPlugin");
	
	if (afkEnt is null) {
		dictionary keys;
		keys["targetname"] = "PlayerStatusPlugin";
		@afkEnt = g_EntityFuncs.CreateEntity( "info_target", keys, true );
	}
	
	CustomKeyvalues@ customKeys = afkEnt.GetCustomKeyvalues();
	
	uint32 afkTier1 = 0;
	uint32 afkTier2 = 0;
	
	// TODO: remove this custom key stuff and update other plugins that used it
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		int afkTime = 0;
		int lagState = LAG_JOINING;
		
		if (plr !is null and plr.IsConnected()) {
			PlayerState@ state = g_player_states[i];
			afkTime = int(g_Engine.time - state.last_not_afk);
			afkTime = afkTime >= afk_tier[0] ? afkTime : 0;
			lagState = state.lag_state;
			
			if (afkTime >= afk_tier[0]) {
				afkTier1 |= (1 << (plr.entindex() & 31));
			}
			if (afkTime >= afk_tier[1]) {
				afkTier2 |= (1 << (plr.entindex() & 31));
			}
		}

		customKeys.SetKeyvalue("$i_afk" + i, afkTime);
		customKeys.SetKeyvalue("$i_state" + i, lagState);
	}
	
	// for quickly checking if a player is afk
	afkEnt.pev.renderfx = afkTier1;
	afkEnt.pev.weapons = afkTier2;
}

HookReturnCode ClientConnect(edict_t@ eEdict, const string &in sNick, const string &in sIp, bool &out bNoJoin, string &out sReason)
{
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, sNick + " is connecting.\n");
	return HOOK_CONTINUE;
}

HookReturnCode ClientJoin(CBasePlayer@ plr)
{		
	int idx = plr.entindex();
	g_player_states[idx].last_use = 0;
	g_player_states[idx].lag_state = LAG_JOINING;
	g_player_states[idx].last_not_afk = g_Engine.time;
	g_player_states[idx].afk_count = 0;
	g_player_states[idx].total_afk = 0;
	g_player_states[idx].afk_message_sent = false;
	g_player_states[idx].lastPostThinkHook = 0;
	
	if (g_EngineFuncs.GetPlayerAuthId( plr.edict() ) == "BOT") {
		g_player_states[idx].lag_state = LAG_NONE;
	}
	
	return HOOK_CONTINUE;
}

HookReturnCode ClientLeave(CBasePlayer@ plr)
{
	int idx = plr.entindex();
	if (g_player_states[idx].lag_state != LAG_NONE) {
		play_sound(plr, error_snd);
	}
	
	float dur = g_Engine.time - g_player_states[idx].last_use;
	if (dur > 1.0f) {
		g_Game.AlertMessage(at_console, "[LagLog] " + plr.pev.netname + " disconnected after " + dur + " lag spike");
		g_Game.AlertMessage(at_logged, "[LagLog] " + plr.pev.netname + " disconnected after " + dur + " lag spike");
	}
		
	
	g_player_states[idx].rendermode_applied = false;
	g_player_states[idx].last_use = 0;
	g_player_states[idx].connection_time = 0;
	g_player_states[idx].afk_message_sent = false;
	g_player_states[idx].lastPostThinkHook = 0;
	g_EntityFuncs.Remove(g_player_states[idx].afk_sprite);
	
	PlayerState@ state = g_player_states[idx];
	string steamid = getUniqueId(plr);
	if (g_afk_stats.exists(steamid)) {
		g_afk_stats[steamid] = int(g_afk_stats[steamid]) + state.get_total_afk_time();
	} else {
		g_afk_stats[steamid] = state.get_total_afk_time();
	}
	
	
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
	
	if ((!ok_to_afk && afkTime > afk_tier[1]) || afkTime > afk_tier[2]) {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "" + plr.pev.netname + " was AFK for " + formatTime(afkTime) + ".\n");
	}
	
	if (g_player_states[idx].lag_state == LAG_JOINING) {
		int loadTime = int((g_Engine.time - g_player_states[idx].connection_time) + 0.5f);		
		string plural = loadTime != 1 ? "s" : "";
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "" + plr.pev.netname + " is now playing.\n");
		g_player_states[idx].lag_state = LAG_NONE;
		g_player_states[idx].last_not_afk = g_Engine.time;
		g_player_states[idx].fully_load_time = g_Engine.time;
	}
}

class CorpseInfo {
	bool hasCorpse = false;
	Vector origin;
	Vector angles;
	int sequence;
	float frame;
	
	CorpseInfo() {}
}

void possess(CBasePlayer@ plr) {
	Math.MakeVectors( plr.pev.v_angle );
	Vector lookDir = g_Engine.v_forward;
	int eidx = plr.entindex();
	
	TraceResult tr;
	g_Utility.TraceLine( plr.pev.origin, plr.pev.origin + lookDir*4096, dont_ignore_monsters, plr.edict(), tr );
	CBasePlayer@ phit = cast<CBasePlayer@>(g_EntityFuncs.Instance( tr.pHit ));
	
	if (phit is null or !phit.IsAlive()) {
		//g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "Look at an AFK player you want to posess, then try again.\n");
		return;
	}
	
	PlayerState@ phitState = g_player_states[phit.entindex()];
	
	if ((tr.vecEndPos - plr.pev.origin).Length() > 256) {
		//g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "Get closer to the player you want to posess, then try again.\n");
		return;
	}
	
	if (possess_map_blacklist.find(g_Engine.mapname) != -1) {
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "Possession is disabled on this map.\n");
		return;
	}

	int timeSinceLast = int(g_Engine.time - g_player_states[eidx].lastPossess);
	int cooldown = POSSESS_COOLDOWN - timeSinceLast;
	if (cooldown > 0) {
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "Wait " + cooldown + " seconds before possessing another player.\n");
		return;
	}
	
	float afkTime = g_Engine.time - phitState.last_not_afk;
	int afkLeft = int((afk_tier[1] - afkTime) + 0.99f);
	if (afkTime < afk_tier[1]) {
		if (afkTime >= afk_tier[0]) {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "" + phit.pev.netname + " hasn't been AFK long enough for possession (" + afkLeft + "s left).\n");
		}
		return;
	}
	
	float liveTime = g_Engine.time - phitState.lastRespawn;
	int liveLeft = int((afk_possess_alive_time - liveTime) + 0.99f);
	if (liveLeft > 0) {
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "" + phit.pev.netname + " hasn't been alive long enough for possession (" + liveLeft + "s left).\n");
		return;
	}
	
	CorpseInfo corpseInfo;
	
	if (plr.GetObserver().IsObserver() && plr.GetObserver().HasCorpse()) {
		CBaseEntity@ ent = null;
		do {
			@ent = g_EntityFuncs.FindEntityByClassname(ent, "deadplayer"); 
			if (ent !is null) {
				CustomKeyvalues@ pCustom = ent.GetCustomKeyvalues();
				CustomKeyvalue ownerKey( pCustom.GetKeyvalue( "$i_hipoly_owner" ) );
				
				if (ownerKey.Exists() && ownerKey.GetInteger() == plr.entindex()) {
					corpseInfo.hasCorpse = true;
					corpseInfo.origin = ent.pev.origin;
					corpseInfo.angles = ent.pev.angles;
					corpseInfo.sequence = ent.pev.sequence;
					corpseInfo.frame = ent.pev.frame;
				}
			}
		} while (ent !is null);
	}
	
	int oldSolid = phit.pev.solid;
	phit.pev.solid = SOLID_NOT;
	plr.Revive();
	plr.pev.takedamage = DAMAGE_NO;
	g_player_states[eidx].lastPossess = g_Engine.time;
	copy_possessed_player(EHandle(plr), EHandle(phit), g_Engine.time, oldSolid, corpseInfo);
}


void copy_possessed_player(EHandle h_ghost, EHandle h_target, float startTime, int oldSolid, CorpseInfo corpseInfo) {
	CBasePlayer@ ghost = cast<CBasePlayer@>(h_ghost.GetEntity());
	CBasePlayer@ target = cast<CBasePlayer@>(h_target.GetEntity());
	
	if (ghost is null or target is null) {
		return;
	}
	
	if (!ghost.IsAlive()) {
		float delay = g_Engine.time - startTime;
		
		if (delay > 3) {
			g_PlayerFuncs.ClientPrint(ghost, HUD_PRINTTALK, "Failed to possess player.\n");
			target.pev.solid = oldSolid;
			ghost.pev.takedamage = DAMAGE_YES;
			g_player_states[ghost.entindex()].lastPossess = -999;
		} else {
			g_Scheduler.SetTimeout("copy_possessed_player", 0.0f, h_ghost, h_target, startTime, oldSolid, corpseInfo);
		}

		return;
	}
	
	ghost.pev.origin = target.pev.origin;
	ghost.pev.angles = target.pev.v_angle;
	ghost.pev.fixangle = FAM_FORCEVIEWANGLES;
	ghost.pev.health = target.pev.health;
	ghost.pev.armorvalue = target.pev.armorvalue;
	ghost.pev.flDuckTime = 26;
	ghost.pev.flags |= FL_DUCKING;
	ghost.pev.view_ofs = Vector(0,0,12);
	ghost.pev.takedamage = DAMAGE_YES;
	
	if (target.IsAlive()) {
		// not starting observer mode because it might be crashing clients
		target.Killed(g_EntityFuncs.Instance( 0 ).pev, GIB_NEVER);
		
		if (corpseInfo.hasCorpse) {
			target.pev.origin = corpseInfo.origin;
			target.pev.angles = corpseInfo.angles;
			target.pev.sequence = corpseInfo.sequence;
			target.pev.frame = corpseInfo.frame;
			te_teleport(target.pev.origin);
			g_SoundSystem.PlaySound(target.edict(), CHAN_VOICE, possess_snd, 1.0f, 0.5f, 0, 150);
		} else {
			target.pev.effects |= EF_NODRAW;
		}
	}
	
	g_SoundSystem.PlaySound(ghost.edict(), CHAN_STATIC, possess_snd, 1.0f, 0.5f, 0, 150);
	te_teleport(ghost.pev.origin);
	
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "" + ghost.pev.netname + " possessed " + target.pev.netname + ".\n");
	g_PlayerFuncs.ClientPrint(target, HUD_PRINTTALK, "" + ghost.pev.netname + " possessed you.\n");
}

void te_teleport(Vector pos, NetworkMessageDest msgType=MSG_BROADCAST, edict_t@ dest=null)
{
	NetworkMessage m(msgType, NetworkMessages::SVC_TEMPENTITY, dest);
	m.WriteByte(TE_TELEPORT);
	m.WriteCoord(pos.x);
	m.WriteCoord(pos.y);
	m.WriteCoord(pos.z);
	m.End();
}

HookReturnCode PlayerPreThink( CBasePlayer@ plr, uint& out uiFlags )
{
	int idx = plr.entindex();
	if (g_player_states[idx].lag_state == LAG_SEVERE_MSG) {
		if (g_player_states[idx].lag_spike_duration == -1) {
			g_player_states[idx].lag_spike_duration = int(g_Engine.time - g_player_states[idx].last_use + 0.5f);
		}
	}
		
	g_player_states[idx].last_use = g_Engine.time;
	
	int buttons = (plr.m_afButtonPressed | plr.m_afButtonReleased) & ~32768; // for some reason the scoreboard button is pressed on death/respawn	
	
	if (buttons != g_player_states[idx].last_button_state) {
		return_from_afk_message(plr);
	
		g_player_states[idx].last_not_afk = g_Engine.time;		
		g_player_states[idx].afk_message_sent = false;
	}
	
	g_player_states[idx].last_button_state = buttons;
	
	if (plr.m_afButtonReleased & IN_USE != 0 and plr.GetObserver().IsObserver()) {
		possess(plr);
	}
	
	if (plr.pev.flags & 4096 != 0) {
		// player is frozen watching a camera (map cutscene
		// so prevent everyone from going AFK by "stopping" the AFK timer
		float delta = g_Engine.time - g_player_states[idx].lastPostThinkHook;
		g_player_states[idx].last_not_afk += delta;
	}
	g_player_states[idx].lastPostThinkHook = g_Engine.time;
	
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
		if (args[0] == "afk?") {
			if (g_Engine.time - last_afk_chat < 60.0f) {
				int cooldown = 60 - int(g_Engine.time - last_afk_chat);
				g_PlayerFuncs.ClientPrintAll(HUD_PRINTCENTER, "Wait " + cooldown + " seconds\n");
				return 2;
			}
			last_afk_chat = g_Engine.time;
		
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
				RelaySay( "Nobody is AFK.\n");
			}
			else if (totalAfk == 1) {
				g_PlayerFuncs.SayTextAll(plr, afkers[0] + " is AFK.\n");
				RelaySay(afkers[0] + " is AFK.\n");
			}
			else if (totalAfk == 2) {
				string afkString = afkers[0] + " and " + afkers[1];
				g_PlayerFuncs.SayTextAll(plr, afkString + " are AFK.\n");
				RelaySay(afkString + " are AFK.\n");
			}
			else if (totalAfk == 3) {
				string afkString = afkers[0] + ", " + afkers[1] + ", and " + afkers[2];
				g_PlayerFuncs.SayTextAll(plr, afkString + " are AFK (" + percent + "% of the server).\n");
				RelaySay(afkString + " are AFK (" + percent + "% of the server).\n");
			}
			else {
				g_PlayerFuncs.SayTextAll(plr, "" + totalAfk + " players are AFK (" + percent + "% of the server).\n");
				RelaySay("" + totalAfk + " players are AFK (" + percent + "% of the server).\n");
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
			return HOOK_HANDLED;
		}
	}
	
	return HOOK_CONTINUE;
}

CClientCommand _listafk("listafk", "AFK player commands", @consoleCmd );

void consoleCmd( const CCommand@ args ) {
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args, true);
}
