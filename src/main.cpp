#include "main.h"
#include "mmlib.h"
#include <algorithm>

using namespace std;

// Description of plugin
plugin_info_t Plugin_info = {
	META_INTERFACE_VERSION,	// ifvers
	"PlayerStatus",	// name
	"1.0",	// version
	__DATE__,	// date
	"w00tguy",	// author
	"https://github.com/wootguy/",	// url
	"PLRSTAT",	// logtag, all caps please
	PT_ANYTIME,	// (when) loadable
	PT_ANYPAUSE,	// (when) unloadable
};


// TODO:
// - connecting joining player is null
// - flashlight + vc should disable afk
// - recovered from a 0 second lag spike
// - afk kick doesnt remove loading icon
// - afk sprite change size
// - show afk sprite for dead but not gibbed players

// PORT TODO:
// check that server prints work

vector<PlayerState> g_player_states;
map<string, int> g_afk_stats; // maps steam id to afk time for players who leave the game

float disconnect_message_time = 4.0f; // player considered disconnected after this many seconds
float min_lag_detect = 0.3f; // minimum amount of a time a player needs to be disconnected before the icon shows

float suppress_lag_sounds_time = 10.0f; // time after joining to silence the lag sounds (can get spammy on map changes)

float dial_loop_dur = 26.0; // duration of the dialup sound loop
float last_afk_chat = -9999;
int afk_possess_alive_time = 20;

const char* ent_tname = "playerstatus_ent"; // for cleanup on plugin exit

SurvivalMode g_SurvivalMode;

set<string> possess_map_blacklist = {
	"fallguys_s2",
	"fallguys_s3",
	"sc5x_bonus",
	"hideandseek",
	"hide_in_grass_v2"
};

set<string> g_zzz_sprite_map_blacklist = {
	"sc5x_bonus",
	"hideandseek",
	"hideandrape_v2",
	"hide_in_grass_v2"
};

// time in seconds for different levels of afk
int afk_tier[] = {
	30,    // cyan (min time)
	60,    // green (message sent)	
	60 * 2,  // yellow
	60 * 5, // orange
	60 * 10, // red
	60 * 20, // purple
};

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

cvar_t* cvar_afk_punish_time;

bool g_precached = false;
bool g_disable_zzz_sprite = false;

PlayerState::PlayerState() {
	last_not_afk = gpGlobals->time;
}

float PlayerState::get_total_afk_time() {
	float total = total_afk;

	// don't count current current afk session unless icon is showing
	float afkTime = gpGlobals->time - last_not_afk;
	if (afkTime > afk_tier[0]) {
		total += afkTime;
	}

	return total;
}

void MapInit(edict_t* pEdictList, int edictCount, int maxClients) {
	PrecacheModel(loading_spr);
	PrecacheModel(warn_spr);
	PrecacheModel(dial_spr);
	PrecacheModel(afk_spr);

	PrecacheSound(error_snd);
	PrecacheSound(exclaim_snd);
	PrecacheSound(popup_snd);
	PrecacheSound(dial_snd);
	PrecacheSound("thunder.wav");
	PrecacheSound(possess_snd);

	g_player_states.resize(0);
	g_player_states.resize(33);

	last_afk_chat = -999;
	g_afk_stats.clear();
	g_precached = true;

	g_disable_zzz_sprite = g_zzz_sprite_map_blacklist.count(STRING(gpGlobals->mapname)) != 0;

	RETURN_META(MRES_IGNORED);
}

void MapInit_post(edict_t* pEdictList, int edictCount, int maxClients) {
	loadSoundCacheFile();
	hook_angelscript("SurvivalMode", "PlayerStatus_SurvivalMode", update_survival_state);
	RETURN_META(MRES_IGNORED);
}

void MapChange() {
	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* p = INDEXENT(i);

		if (!isValidPlayer(p)) {
			continue;
		}

		PlayerState& state = g_player_states[i];
		string steamid = getPlayerUniqueId(p);
		int totalAfk = int(state.get_total_afk_time());

		if (g_afk_stats.count(steamid)) {
			totalAfk += int(g_afk_stats[steamid]);
			g_afk_stats.erase(steamid);
		}

		string msg = "[AfkStats] " + steamid + " " + to_string(totalAfk) + " " + STRING(p->v.netname);
		println(msg);
		logln(msg);
	}

	for (auto iter : g_afk_stats) {
		int afkTime = iter.second;
		string msg = "[AfkStats] " + iter.first + " " + to_string(afkTime) + " \\disconnected_player\\\n";
		println(msg);
		logln(msg);
	}

	RETURN_META(MRES_IGNORED);
}

// looped sounds sometimes get stuck looping forever, so manually check if the ent still exists
void loop_sound(EHandle h_target, string snd, float vol, float loopDelay) {
	CBasePlayer* target = (CBasePlayer*)(h_target.GetEntity());
	if (!target || !target->IsConnected() || g_player_states[target->entindex()].lag_state != LAG_SEVERE_MSG) {
		return;
	}

	play_sound(target, snd, vol, loopDelay);
}

void play_sound(CBasePlayer* target, string snd, float vol, float loopDelay) {
	int pit = 100;
	PlaySound(target->edict(), CHAN_VOICE, snd, vol, 0.8f, 0, pit, 0, true, target->pev->origin);

	if (loopDelay > 0) {
		g_Scheduler.SetTimeout(loop_sound, loopDelay, EHandle(target), snd, vol, loopDelay);
	}
}

void update_player_status() {
	if (!g_precached || g_disable_zzz_sprite) {
		return;
	}

	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* eplr = INDEXENT(i);
		CBasePlayer* plr = (CBasePlayer*)GET_PRIVATE(eplr);

		if (!isValidPlayer(eplr) || !plr) {
			continue;
		}

		PlayerState& state = g_player_states[i];

		if (!plr || !plr->IsConnected()) {
			RemoveEntity(state.loading_sprite);
			RemoveEntity(state.afk_sprite);
			if (state.lag_state != LAG_NONE) {
				state.lag_state = LAG_NONE;
			}
			continue;
		}

		if (plr->IsAlive() && !state.wasAlive) {
			state.lastRespawn = gpGlobals->time;
		}
		state.wasAlive = plr->IsAlive();

		float lastPacket = gpGlobals->time - state.last_use;

		bool isLagging = lastPacket > min_lag_detect || state.lag_state == LAG_JOINING;
		bool shouldSuppressLagsound = (gpGlobals->time - state.fully_load_time) < suppress_lag_sounds_time;

		if (lastPacket > disconnect_message_time) {
			if (state.lag_state == LAG_NONE) {
				state.lag_state = LAG_SEVERE_MSG;
				ClientPrintAll(HUD_PRINTNOTIFY, (string(STRING(plr->pev->netname)) + " lost connection to the server.\n").c_str());
				if (!shouldSuppressLagsound)
					play_sound(plr, dial_snd, 0.3f, dial_loop_dur);

				Vector spritePos = plr->pev->origin + Vector(0, 0, 44);

				RemoveEntity(state.loading_sprite);

				map<string,string> keys;
				keys["origin"] = vecToString(spritePos);
				keys["model"] = dial_spr;
				keys["rendermode"] = "2";
				keys["renderamt"] = "255";
				keys["framerate"] = "2";
				keys["scale"] = "0.25";
				keys["spawnflags"] = "1";
				keys["targetname"] = ent_tname;
				CBaseEntity* newLoadSprite = CreateEntity("env_sprite", keys, true);
				state.loading_sprite = EHandle(newLoadSprite);
			}
		}

		Vector spritePos = plr->pev->origin + Vector(0, 0, 44);

		if (isLagging)
		{
			RemoveEntity(state.afk_sprite);

			if (state.loading_sprite.IsValid()) {
				CBaseEntity* loadSprite = state.loading_sprite;
				loadSprite->pev->origin = spritePos;
			}
			else {
				map<string, string> keys;
				keys["origin"] = vecToString(spritePos);
				keys["model"] = state.lag_state == LAG_JOINING ? loading_spr : warn_spr;
				keys["rendermode"] = "2";
				keys["renderamt"] = "255";
				keys["framerate"] = to_string(loading_spr_framerate);
				keys["scale"] = state.lag_state == LAG_JOINING ? "0.15" : ".50";
				keys["spawnflags"] = "1";
				keys["targetname"] = ent_tname;
				CBaseEntity* loadSprite = CreateEntity("env_sprite", keys, true);
				state.loading_sprite = EHandle(loadSprite);

				// TODO: Called twice before reverting rendermode somehow

				if (!state.rendermode_applied && state.lag_state != LAG_JOINING) {
					// save old render info
					RenderInfo info;
					info.rendermode = plr->pev->rendermode;
					info.renderamt = plr->pev->renderamt;
					info.renderfx = plr->pev->renderfx;
					state.render_info = info;

					plr->pev->rendermode = 2;
					plr->pev->renderamt = 144; // min amt that doesn't dip below 128 when fading (which causes rendering errors on some models)
					plr->pev->renderfx = 2;

					//println("Applying ghost rendermode to " + plr->pev->netname);

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
				ClientPrintAll(HUD_PRINTNOTIFY, (string(STRING(plr->pev->netname)) + " recovered from " + a_or_an + to_string(dur) + " second lag spike.\n").c_str());
				println((string("[LagLog] ") + STRING(plr->pev->netname) + " recovered from " + a_or_an + to_string(dur) + " second lag spike.\n").c_str());
				logln((string("[LagLog] ") + STRING(plr->pev->netname) + " recovered from " + a_or_an + to_string(dur) + " second lag spike.\n").c_str());
			}

			if (state.rendermode_applied) {
				if (!shouldSuppressLagsound)
					play_sound(plr, popup_snd, 0.3f);
				plr->pev->rendermode = state.render_info.rendermode;
				plr->pev->renderamt = state.render_info.renderamt;
				plr->pev->renderfx = state.render_info.renderfx;
				state.rendermode_applied = false;
				//println("Restored normal rendermode to " + plr->pev->netname);
			}

			RemoveEntity(state.loading_sprite);

			state.lag_spike_duration = -1;

			bool ok_to_afk = g_SurvivalMode.active && !plr->IsAlive();

			float afkTime = gpGlobals->time - state.last_not_afk;
			float gracePeriod = 2.0f; // allow other plugins to get the updated AFK state before the sprite is shown
			if (!ok_to_afk && afkTime > afk_tier[0] + gracePeriod && (plr->pev->effects & EF_NODRAW) == 0) {
				if (!state.afk_sprite.IsValid()) {
					map<string,string> keys;
					keys["model"] = afk_spr;
					keys["rendermode"] = "2";
					keys["renderamt"] = "255";
					keys["rendercolor"] = "255 255 255";
					keys["framerate"] = "10";
					keys["scale"] = ".15";
					keys["spawnflags"] = "1";
					keys["targetname"] = ent_tname;
					CBaseEntity* spr = CreateEntity("env_sprite", keys, true);
					state.afk_sprite = EHandle(spr);
				}

				CBaseEntity* afkSprite = state.afk_sprite;
				afkSprite->pev->movetype = MOVETYPE_FOLLOW;
				afkSprite->pev->aiment = plr->edict();

				Vector color = Vector(0, 255, 255);
				if (afkTime > afk_tier[5]) {
					color = Vector(128, 0, 255);
				}
				else if (afkTime > afk_tier[4]) {
					color = Vector(255, 0, 0);
				}
				else if (afkTime > afk_tier[3]) {
					color = Vector(255, 128, 0);
				}
				else if (afkTime > afk_tier[2]) {
					color = Vector(255, 255, 0);
				}
				else if (afkTime > afk_tier[1]) {
					color = Vector(0, 255, 0);
				}
				else {
					color = Vector(0, 255, 255);
				}

				afkSprite->pev->rendercolor = color;
			}
			else {
				RemoveEntity(state.afk_sprite);
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
					ClientPrintAll(HUD_PRINTNOTIFY, (string(STRING(plr->pev->netname)) + " is AFK for the " + to_string(state.afk_count) + suffix + " time.\n").c_str());
				}
				else if (state.afk_count > 1) {
					ClientPrintAll(HUD_PRINTNOTIFY, (string(STRING(plr->pev->netname)) + " is AFK again.\n").c_str());
				}
				else {
					ClientPrintAll(HUD_PRINTNOTIFY, (string(STRING(plr->pev->netname)) + " is AFK.\n").c_str());
				}
			}
		}
	}
}

void punish_afk_players() {
	if (cvar_afk_punish_time->value == 0 || !g_precached) {
		return;
	}

	int numAliveActive = 0;
	int numAliveAfk = 0;
	int numPlayers = 0;
	vector<CBasePlayer*> afkPlayers;

	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		CBasePlayer* plr = (CBasePlayer*)GET_PRIVATE(INDEXENT(i));

		if (!plr || !plr->IsConnected()) {
			continue;
		}

		numPlayers += 1;

		PlayerState& state = g_player_states[i];

		int afkTime = int(gpGlobals->time - state.last_not_afk);
		bool isAfk = afkTime >= cvar_afk_punish_time->value;

		if (isAfk) {
			if (plr->IsAlive()) {
				numAliveAfk += 1;
			}

			afkPlayers.push_back(plr);
		}
		else if (plr->IsAlive()) {
			numAliveActive += 1;
		}
	}

	bool everyoneIsAfk = int(afkPlayers.size()) == numPlayers;
	bool lastLivingPlayersAreAfk = numAliveActive == 0 && numAliveAfk > 0;

	if (g_SurvivalMode.active && lastLivingPlayersAreAfk && !everyoneIsAfk) {
		// all living players are AFK
		if (g_survival_afk_kill_countdown == KILL_AFK_IN_SURVIVAL_DELAY) {
			ClientPrintAll(HUD_PRINTTALK, ("All living players are AFK will be killed in " + to_string(KILL_AFK_IN_SURVIVAL_DELAY) + " seconds.\n").c_str());
		}

		g_survival_afk_kill_countdown -= 1;

		if (g_survival_afk_kill_countdown < 0) {
			g_survival_afk_kill_countdown = KILL_AFK_IN_SURVIVAL_DELAY;

			for (int i = 0; i < afkPlayers.size(); i++) {
				CBasePlayer* plr = afkPlayers[i];

				if (plr->IsAlive()) {
					TraceResult tr;
					TRACE_LINE(plr->pev->origin, plr->pev->origin + Vector(0, 0, 1) * 4096, ignore_monsters, plr->edict(), &tr);

					te_beampoints(plr->pev->origin, tr.vecEndPos, "sprites/laserbeam.spr", 0, 1, 2, 16, 64, Color(175, 215, 255, 255), 255);
					te_dlight(plr->pev->origin, 24, Color(175, 215, 255), 4, 88);

					RemoveEntity(afkPlayers[i]->edict());
				}
			}

			PlaySound(INDEXENT(0), CHAN_STATIC, "thunder.wav", 0.67f, 0.0f, 0, 100);
		}
	}
	else {
		if (g_survival_afk_kill_countdown != KILL_AFK_IN_SURVIVAL_DELAY) {
			string reason = "Someone woke up.";
			if (everyoneIsAfk) {
				reason = "Everyone is AFK now...";
			}
			else if (!g_SurvivalMode.active) {
				reason = "Survival mode was disabled.";
			}

			ClientPrintAll(HUD_PRINTTALK, ("AFK kill aborted. " + reason + "\n").c_str());
		}
		g_survival_afk_kill_countdown = KILL_AFK_IN_SURVIVAL_DELAY;
	}

	if (numPlayers == gpGlobals->maxClients && afkPlayers.size() > 0) {
		// kick a random AFK player to make room for someone who wants to play
		CBasePlayer* randomPlayer = afkPlayers[RANDOM_LONG(0, afkPlayers.size() - 1)];
		string pname = STRING(randomPlayer->pev->netname);

		g_engfuncs.pfnServerCommand((char*)("kick #" + to_string(g_engfuncs.pfnGetPlayerUserId(randomPlayer->edict())) + " You were AFK on a full server.\n").c_str());
		g_engfuncs.pfnServerExecute();
		ClientPrintAll(HUD_PRINTTALK, (pname + " was kicked for being AFK on a full server.\n").c_str());
	}
}

void update_cross_plugin_state() {
	if (gpGlobals->time < 5.0f || !g_precached) {
		return;
	}

	edict_t* afkEnt = g_engfuncs.pfnFindEntityByString(NULL, "targetname", "PlayerStatusPlugin");

	if (!isValidFindEnt(afkEnt)) {
		map<string, string> keys;
		keys["targetname"] = "PlayerStatusPlugin";
		afkEnt = CreateEntity("info_target", keys, true)->edict();
	}

	uint32_t afkTier1 = 0;
	uint32_t afkTier2 = 0;
	uint32_t isLoaded = 0;

	// TODO: update other plugins that used the old custom keyvalues
	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		CBasePlayer* plr = (CBasePlayer*)GET_PRIVATE(INDEXENT(i));

		int afkTime = 0;
		int lagState = LAG_JOINING;

		if (plr && plr->IsConnected()) {
			PlayerState& state = g_player_states[i];
			afkTime = int(gpGlobals->time - state.last_not_afk);
			afkTime = afkTime >= afk_tier[0] ? afkTime : 0;
			lagState = state.lag_state;
			uint32_t plrBit = (1 << (plr->entindex() & 31));

			if (afkTime >= afk_tier[0]) {
				afkTier1 |= plrBit;
			}
			if (afkTime >= afk_tier[1]) {
				afkTier2 |= plrBit;
			}
			if (lagState != LAG_JOINING) {
				isLoaded |= plrBit;
			}
		}
	}

	// for quickly checking if a player is afk
	afkEnt->v.renderfx = afkTier1;
	afkEnt->v.weapons = afkTier2;
	afkEnt->v.iuser4 = isLoaded;
}


int ClientConnect(edict_t* eEdict, const char* sNick, const char* sIp, char* sReason)
{
	ClientPrintAll(HUD_PRINTNOTIFY, (string(sNick) + " is connecting.\n").c_str());
	RETURN_META_VALUE(MRES_IGNORED, 0);
}

void ClientJoin(edict_t* plr)
{
	int idx = ENTINDEX(plr);
	g_player_states[idx].last_use = 0;
	g_player_states[idx].lag_state = LAG_JOINING;
	g_player_states[idx].last_not_afk = gpGlobals->time;
	g_player_states[idx].afk_count = 0;
	g_player_states[idx].total_afk = 0;
	g_player_states[idx].afk_message_sent = false;
	g_player_states[idx].lastPostThinkHook = 0;

	if (getPlayerUniqueId(plr) == "BOT") {
		g_player_states[idx].lag_state = LAG_NONE;
	}

	RETURN_META(MRES_IGNORED);
}

void ClientLeave(edict_t* plr)
{
	int idx = ENTINDEX(plr);
	if (g_player_states[idx].lag_state != LAG_NONE) {
		play_sound((CBasePlayer*)GET_PRIVATE(plr), error_snd);
	}
	
	float dur = gpGlobals->time - g_player_states[idx].last_use;
	if (dur > 1.0f) {
		println((string("[LagLog] ") + STRING(plr->v.netname) + " disconnected after " + to_string(dur) + " lag spike").c_str());
		logln((string("[LagLog] ") + STRING(plr->v.netname) + " disconnected after " + to_string(dur) + " lag spike").c_str());
	}


	g_player_states[idx].rendermode_applied = false;
	g_player_states[idx].last_use = 0;
	g_player_states[idx].connection_time = 0;
	g_player_states[idx].afk_message_sent = false;
	g_player_states[idx].lastPostThinkHook = 0;
	g_player_states[idx].lag_state = LAG_NONE;
	RemoveEntity(g_player_states[idx].loading_sprite);
	RemoveEntity(g_player_states[idx].afk_sprite);

	PlayerState& state = g_player_states[idx];
	string steamid = getPlayerUniqueId(plr);
	if (g_afk_stats.count(steamid)) {
		g_afk_stats[steamid] = int(g_afk_stats[steamid]) + state.get_total_afk_time();
	}
	else {
		g_afk_stats[steamid] = state.get_total_afk_time();
	}

	RETURN_META(MRES_IGNORED);
}

string formatTime(float t, bool statsPage = false) {
	int rounded = int(t + 0.5f);

	int minutes = rounded / 60;
	int seconds = rounded % 60;

	if (statsPage) {
		string ss = to_string(seconds);
		if (seconds < 10) {
			ss = "0" + ss;
		}
		return to_string(minutes) + ":" + ss + "";
	}
	if (minutes > 0) {
		string ss = to_string(seconds);
		if (seconds < 10) {
			ss = "0" + ss;
		}
		return to_string(minutes) + ":" + ss + " minutes";
	}
	else {
		return to_string(seconds) + " seconds";
	}
}

void return_from_afk_message(CBasePlayer* plr) {
	int idx = plr->entindex();
	float afkTime = gpGlobals->time - g_player_states[idx].last_not_afk;

	bool ok_to_afk = g_SurvivalMode.active && !plr->IsAlive();

	if (afkTime > afk_tier[1])
		g_player_states[idx].total_afk += afkTime;

	if ((!ok_to_afk && afkTime > afk_tier[1]) || afkTime > afk_tier[2]) {
		ClientPrintAll(HUD_PRINTNOTIFY, (string(STRING(plr->pev->netname)) + " was AFK for " + formatTime(afkTime) + ".\n").c_str());
	}

	if (g_player_states[idx].lag_state == LAG_JOINING) {
		int loadTime = int((gpGlobals->time - g_player_states[idx].connection_time) + 0.5f);
		string plural = loadTime != 1 ? "s" : "";
		ClientPrintAll(HUD_PRINTNOTIFY, (string(STRING(plr->pev->netname)) + " is now playing.\n").c_str());
		g_player_states[idx].lag_state = LAG_NONE;
		g_player_states[idx].last_not_afk = gpGlobals->time;
		g_player_states[idx].fully_load_time = gpGlobals->time;
	}
}

void copy_possessed_player(EHandle h_ghost, EHandle h_target, float startTime, int oldSolid, CorpseInfo corpseInfo) {
	CBasePlayer* ghost = (CBasePlayer*)(h_ghost.GetEntity());
	CBasePlayer* target = (CBasePlayer*)(h_target.GetEntity());

	if (!ghost || !target) {
		return;
	}

	if (!ghost->IsAlive()) {
		float delay = gpGlobals->time - startTime;

		if (delay > 3) {
			ClientPrint(ghost->edict(), HUD_PRINTTALK, "Failed to possess player.\n");
			target->pev->solid = oldSolid;
			ghost->pev->takedamage = DAMAGE_YES;
			g_player_states[ghost->entindex()].lastPossess = -999;
		}
		else {
			g_Scheduler.SetTimeout(copy_possessed_player, 0.0f, h_ghost, h_target, startTime, oldSolid, corpseInfo);
		}

		return;
	}

	ghost->pev->origin = target->pev->origin;
	ghost->pev->angles = target->pev->v_angle;
	ghost->pev->fixangle = FAM_FORCEVIEWANGLES;
	ghost->pev->health = target->pev->health;
	ghost->pev->armorvalue = target->pev->armorvalue;
	ghost->pev->flDuckTime = 26;
	ghost->pev->flags |= FL_DUCKING;
	ghost->pev->view_ofs = Vector(0, 0, 12);
	ghost->pev->takedamage = DAMAGE_YES;

	if (target->IsAlive()) {
		// not starting observer mode because it might be crashing clients
		Killed(target->edict(), INDEXENT(0), GIB_NEVER);

		if (corpseInfo.hasCorpse) {
			target->pev->origin = corpseInfo.origin;
			target->pev->angles = corpseInfo.angles;
			target->pev->sequence = corpseInfo.sequence;
			target->pev->frame = corpseInfo.frame;
			te_teleport(target->pev->origin);
			PlaySound(target->edict(), CHAN_VOICE, possess_snd, 1.0f, 0.5f, 0, 150);
		}
		else {
			target->pev->effects |= EF_NODRAW;
		}
	}

	PlaySound(ghost->edict(), CHAN_STATIC, possess_snd, 1.0f, 0.5f, 0, 150);
	te_teleport(ghost->pev->origin);

	ClientPrintAll(HUD_PRINTNOTIFY, (string(STRING(ghost->pev->netname)) + " possessed " + STRING(target->pev->netname) + ".\n").c_str());
	ClientPrint(target->edict(), HUD_PRINTTALK, (string(STRING(ghost->pev->netname)) + " possessed you.\n").c_str());
}

void possess(CBasePlayer* plr) {
	MAKE_VECTORS(plr->pev->v_angle);
	Vector lookDir = gpGlobals->v_forward;
	int eidx = plr->entindex();

	TraceResult tr;
	TRACE_LINE(plr->pev->origin, plr->pev->origin + lookDir * 4096, dont_ignore_monsters, plr->edict(), &tr);
	CBasePlayer* phit = (CBasePlayer*)(GET_PRIVATE(tr.pHit));

	if (!phit || !phit->IsAlive()) {
		//ClientPrint(plr, HUD_PRINTTALK, "Look at an AFK player you want to posess, then try again.\n");
		return;
	}

	PlayerState& phitState = g_player_states[phit->entindex()];

	if ((tr.vecEndPos - plr->pev->origin).Length() > 256) {
		//ClientPrint(plr, HUD_PRINTTALK, "Get closer to the player you want to posess, then try again.\n");
		return;
	}

	if (possess_map_blacklist.count(STRING(gpGlobals->mapname))) {
		ClientPrint(plr->edict(), HUD_PRINTTALK, "Possession is disabled on this map.\n");
		return;
	}

	int timeSinceLast = int(gpGlobals->time - g_player_states[eidx].lastPossess);
	int cooldown = POSSESS_COOLDOWN - timeSinceLast;
	if (cooldown > 0) {
		ClientPrint(plr->edict(), HUD_PRINTTALK, ("Wait " + to_string(cooldown) + " seconds before possessing another player.\n").c_str());
		return;
	}

	float afkTime = gpGlobals->time - phitState.last_not_afk;
	int afkLeft = int((afk_tier[1] - afkTime) + 0.99f);
	if (afkTime < afk_tier[1]) {
		if (afkTime >= afk_tier[0]) {
			ClientPrint(plr->edict(), HUD_PRINTTALK, (string(STRING(phit->pev->netname)) + " hasn't been AFK long enough for possession (" + to_string(afkLeft) + "s left).\n").c_str());
		}
		return;
	}

	float liveTime = gpGlobals->time - phitState.lastRespawn;
	int liveLeft = int((afk_possess_alive_time - liveTime) + 0.99f);
	if (liveLeft > 0) {
		ClientPrint(plr->edict(), HUD_PRINTTALK, (string(STRING(phit->pev->netname)) + " hasn't been alive long enough for possession (" + to_string(liveLeft) + "s left).\n").c_str());
		return;
	}

	CorpseInfo corpseInfo;

	if (plr->IsObserver()) {
		edict_t* ent = NULL;
		do {
			ent = g_engfuncs.pfnFindEntityByString(ent, "classname", "deadplayer");
			if (isValidFindEnt(ent)) {
				int ownerId = readCustomKeyvalueInteger(ent, "$i_hipoly_owner");

				if (ownerId == plr->entindex()) {
					corpseInfo.hasCorpse = true;
					corpseInfo.origin = ent->v.origin;
					corpseInfo.angles = ent->v.angles;
					corpseInfo.sequence = ent->v.sequence;
					corpseInfo.frame = ent->v.frame;
				}
			}
		} while (isValidFindEnt(ent));
	}

	int oldSolid = phit->pev->solid;
	phit->pev->solid = SOLID_NOT;
	Revive(plr->edict());
	plr->pev->takedamage = DAMAGE_NO;
	g_player_states[eidx].lastPossess = gpGlobals->time;
	copy_possessed_player(EHandle(plr), EHandle(phit), gpGlobals->time, oldSolid, corpseInfo);
}

void PlayerPreThink(edict_t* eplr)
{
	CBasePlayer* plr = (CBasePlayer*)GET_PRIVATE(eplr);

	int idx = ENTINDEX(eplr);
	if (g_player_states[idx].lag_state == LAG_SEVERE_MSG) {
		if (g_player_states[idx].lag_spike_duration == -1) {
			g_player_states[idx].lag_spike_duration = int(gpGlobals->time - g_player_states[idx].last_use + 0.5f);
		}
	}

	g_player_states[idx].last_use = gpGlobals->time;

	int buttons = (plr->m_afButtonPressed | plr->m_afButtonReleased) & ~32768; // for some reason the scoreboard button is pressed on death/respawn	

	if (buttons != g_player_states[idx].last_button_state) {
		return_from_afk_message(plr);

		g_player_states[idx].last_not_afk = gpGlobals->time;
		g_player_states[idx].afk_message_sent = false;
	}

	g_player_states[idx].last_button_state = buttons;

	if ((plr->m_afButtonReleased & IN_USE) && plr->IsObserver()) {
		possess(plr);
	}

	if (plr->pev->flags & 4096) {
		// player is frozen watching a camera (map cutscene
		// so prevent everyone from going AFK by "stopping" the AFK timer
		float delta = gpGlobals->time - g_player_states[idx].lastPostThinkHook;
		g_player_states[idx].last_not_afk += delta;
	}
	g_player_states[idx].lastPostThinkHook = gpGlobals->time;

	RETURN_META(MRES_IGNORED);
}

bool doCommand(edict_t* eplr) {
	bool isAdmin = AdminLevel(eplr) >= ADMIN_YES;

	CommandArgs args = CommandArgs();
	args.loadArgs();

	CBasePlayer* plr = (CBasePlayer*)GET_PRIVATE(eplr);

	if (!args.isConsoleCmd) {
		return_from_afk_message(plr);
		g_player_states[plr->entindex()].last_not_afk = gpGlobals->time;
	}

	if (args.ArgC() > 0)
	{
		if (args.ArgV(0) == "afk?") {
			if (gpGlobals->time - last_afk_chat < 60.0f) {
				int cooldown = 60 - int(gpGlobals->time - last_afk_chat);
				ClientPrintAll(HUD_PRINTCENTER, ("Wait " + to_string(cooldown) + " seconds\n").c_str());
				return true;
			}
			last_afk_chat = gpGlobals->time;

			int totalAfk = 0;
			int totalPlayers = 0;

			vector<string> afkers;

			for (int i = 1; i <= gpGlobals->maxClients; i++) {
				edict_t* p = INDEXENT(i);

				if (!isValidPlayer(p)) {
					continue;
				}

				PlayerState& state = g_player_states[i];

				float afkTime = gpGlobals->time - state.last_not_afk;
				if (afkTime > afk_tier[0]) {
					totalAfk++;
					afkers.push_back(STRING(p->v.netname));
				}
				totalPlayers++;
			}

			int percent = int((float(totalAfk) / float(totalPlayers)) * 100);

			if (totalAfk == 0) {
				ClientPrintAll(HUD_PRINTTALK, "Nobody is AFK.\n");
				RelaySay("Nobody is AFK.\n");
			}
			else if (totalAfk == 1) {
				ClientPrintAll(HUD_PRINTTALK, (afkers[0] + " is AFK.\n").c_str());
				RelaySay(afkers[0] + " is AFK.\n");
			}
			else if (totalAfk == 2) {
				string afkString = afkers[0] + " && " + afkers[1];
				ClientPrintAll(HUD_PRINTTALK, (afkString + " are AFK.\n").c_str());
				RelaySay(afkString + " are AFK.\n");
			}
			else if (totalAfk == 3) {
				string afkString = afkers[0] + ", " + afkers[1] + ", && " + afkers[2];
				ClientPrintAll(HUD_PRINTTALK, (afkString + " are AFK (" + to_string(percent) + "% of the server).\n").c_str());
				RelaySay(afkString + " are AFK (" + to_string(percent) + "% of the server).\n");
			}
			else {
				ClientPrintAll(HUD_PRINTTALK, (to_string(totalAfk) + " players are AFK (" + to_string(percent) + "% of the server).\n").c_str());
				RelaySay(to_string(totalAfk) + " players are AFK (" + to_string(percent) + "% of the server).\n");
			}

			return 1;
		}

		if (args.ArgV(0) == ".listafk") {
			int totalAfk = 0;
			int totalPlayers = 0;

			vector<AfkStat> afkStats;

			for (int i = 1; i <= gpGlobals->maxClients; i++) {
				edict_t* p = INDEXENT(i);

				if (!isValidPlayer(p)) {
					continue;
				}

				PlayerState& state = g_player_states[i];

				AfkStat stat;
				stat.name = STRING(p->v.netname);
				stat.time = state.get_total_afk_time();
				stat.state = &state;

				afkStats.push_back(stat);
			}

			sort(afkStats.begin(), afkStats.end(), [](const AfkStat& a, const AfkStat& b) -> bool {
				return a.time > b.time;
			});

			ClientPrint(eplr, HUD_PRINTCONSOLE, "\nAFK times for this map(MINUTES:SECONDS)\n");
			ClientPrint(eplr, HUD_PRINTCONSOLE, "\n   Player Name              Total    AFK Now ? \n");
			ClientPrint(eplr, HUD_PRINTCONSOLE, "------------------------------------------------\n");

			for (int i = 0; i < afkStats.size(); i++) {
				string pname = afkStats[i].name;

				while (pname.size() < 24) {
					pname += " ";
				}
				if (pname.size() > 24) {
					pname = pname.substr(0, 21) + "...";
				}

				string idx = "" + (i + 1);
				if (i + 1 < 10) {
					idx = " " + idx;
				}

				string total = formatTime(afkStats[i].time, true) + "     ";
				string afkNow = (gpGlobals->time - afkStats[i].state->last_not_afk) > afk_tier[0] ? "  Yes" : "  No";

				ClientPrint(eplr, HUD_PRINTCONSOLE, (idx + ") " + pname + " " + total + afkNow + "\n").c_str());
			}
			ClientPrint(eplr, HUD_PRINTCONSOLE, "------------------------------------------------\n\n");
			return true;
		}
	}

	return 0;
}

// called before angelscript hooks
void ClientCommand(edict_t* pEntity) {
	META_RES ret = doCommand(pEntity) ? MRES_SUPERCEDE : MRES_IGNORED;
	RETURN_META(ret);
}

void StartFrame() {
	g_Scheduler.Think();
	RETURN_META(MRES_IGNORED);
}

void update_survival_state() {
	CommandArgs args = CommandArgs();
	args.loadArgs();

	g_SurvivalMode.enabled = atoi(args.ArgV(1).c_str());
	g_SurvivalMode.active = atoi(args.ArgV(2).c_str());
}

void PluginInit() {
	g_player_states.resize(33);

	g_Scheduler.SetInterval(update_player_status, 0.1f, -1);
	g_Scheduler.SetInterval(update_cross_plugin_state, 1.0f, -1);
	g_Scheduler.SetInterval(punish_afk_players, 1.0f, -1);
	
	hook_angelscript("SurvivalMode", "PlayerStatus_SurvivalMode", update_survival_state);
	
	// players afk for this long may be killed/kicked
	cvar_afk_punish_time = RegisterCVar("afk_penalty_time", "60", 60, 0);
	
	g_dll_hooks.pfnClientCommand = ClientCommand;
	g_dll_hooks.pfnClientDisconnect = ClientLeave;
	g_dll_hooks.pfnPlayerPreThink = PlayerPreThink;
	g_dll_hooks.pfnClientConnect = ClientConnect;
	g_dll_hooks.pfnClientPutInServer = ClientJoin;
	g_dll_hooks.pfnServerActivate = MapInit;
	g_dll_hooks_post.pfnServerActivate = MapInit_post;
	g_dll_hooks_post.pfnServerDeactivate = MapChange;
	g_dll_hooks.pfnStartFrame = StartFrame;

	if (gpGlobals->time > 4) {
		loadSoundCacheFile();
	}
}

void PluginExit() {
	vector<edict_t*> removeEdicts;
	edict_t* ent = NULL;
	do {
		ent = g_engfuncs.pfnFindEntityByString(ent, "targetname", ent_tname);
		if (isValidFindEnt(ent)) {
			removeEdicts.push_back(ent);
		}
	} while (isValidFindEnt(ent));

	// can't wait until next frame to remove, must be done now
	for (int i = 0; i < removeEdicts.size(); i++) {
		REMOVE_ENTITY(removeEdicts[i]);
	}

	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* plr = INDEXENT(i);

		if (!isValidPlayer(plr)) {
			continue;
		}

		PlayerState& state = g_player_states[i];

		if (state.rendermode_applied) {
			plr->v.rendermode = state.render_info.rendermode;
			plr->v.renderamt = state.render_info.renderamt;
			plr->v.renderfx = state.render_info.renderfx;
		}
	}
}