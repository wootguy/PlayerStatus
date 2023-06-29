#pragma once
#include "private_api.h"
#include <vector>
#include <set>
#include <map>
#include <string>

enum LAG_STATES {
	LAG_NONE,
	LAG_SEVERE_MSG,
	LAG_JOINING
};

struct RenderInfo {
	int rendermode = 0;
	int renderfx = 0;
	float renderamt = 0;
};

struct SurvivalMode {
	bool enabled = false;
	bool active = false;
};

struct CorpseInfo {
	bool hasCorpse = false;
	Vector origin;
	Vector angles;
	int sequence = 0;
	float frame = 0;
};

struct PlayerState {
	float last_use = 0; // last time playerUse function was called for player (no calls = packet loss or not connected)
	int lag_spike_duration = 0; // time since last player packet when state is LAG_SEVERE_MSG
	EHandle loading_sprite; // status shown above head
	EHandle afk_sprite;
	int lag_state = LAG_NONE;
	RenderInfo render_info; // for undoing the disconnected render model
	bool rendermode_applied = false; // prevent applying rendermode twice (breaking the undo method)
	float connection_time = 0; // time the player first connected on this map (resets if client aborts connection)
	float last_not_afk = 0; // last time player pressed any buttons or sent a chat message
	int last_button_state = 0;
	bool afk_message_sent = false; // true after min_afk_message_time
	int afk_count = 0; // number of times afk'd this map
	float total_afk = 0; // total time afk (minus the current afk session)
	float fully_load_time = 0; // time the player last fully loaded into the server
	float lastPostThinkHook = 0; // last time the postThinkHook call ran for this player
	float lastPossess = 0;
	float lastRespawn = 0;
	bool wasAlive = false;

	PlayerState();

	float get_total_afk_time();
};

struct AfkStat {
	std::string name;
	float time;
	PlayerState* state;
};

void play_sound(CBasePlayer* target, std::string snd, float vol = 1.0f, float loopDelay = 0);
void update_survival_state();