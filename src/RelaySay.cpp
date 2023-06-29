#include "RelaySay.h"
#include "meta_init.h"
#include "misc_utils.h"
#include "Scheduler.h"
#include <algorithm>
#include <map>

using namespace std;

int g_tname_id = 0;

void Failsafe(EHandle hEntity)
{
    if (hEntity.IsValid())
        REMOVE_ENTITY(hEntity);
}

void RelaySay(string message)
{
    // strip any newlines, ChatBridge.as takes care
    message.erase(std::remove(message.begin(), message.end(), '\n'), message.end());

    const string targetname = "twlz_tmp_" + to_string(g_tname_id++);
    const string caller = Plugin_info.name;

    println(("<RelaySay " + caller + ">: " + message + "\n").c_str());

    replaceString(message, "\\", "\\\\");// escape backslashes, or the entity fucks them up

    map<string,string> keys = {
      { "targetname",           targetname },
      { "$s_twlz_relay_caller", caller     },
      { "$s_twlz_relay_msg",    message    }
    };
    CBaseEntity* pEntity = CreateEntity("info_target", keys);
    g_Scheduler.SetTimeout(Failsafe, 2.0f, EHandle(pEntity)); // ChatBridge.as must pick up pEntity in less than this time
}
