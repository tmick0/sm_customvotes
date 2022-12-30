#include <sourcemod>
#include <convars>
#include <autoexecconfig>
#include <adt_trie>
#include <textparse>
#include <regex>
#include <sdktools>
#include <cstrike>

#pragma newdecls required

public Plugin myinfo =
{
    name = "customvotes",
    author = "tmick0",
    description = "configurable voting",
    version = "0.1",
    url = "github.com/tmick0/sm_customvotes"
};

// cvar strings
#define CVAR_ENABLE "sm_custovmotes_enable"
#define CVAR_CONFIG "sm_customvotes_config"

// cmd strings
#define CMD_RELOAD "sm_customvotes_reload"

// config defaults
#define DEFAULT_RATIO 0.5
#define DEFAULT_DURATION -1.0
#define DEFAULT_COOLDOWN 0.0
#define DEFAULT_VOTETEXT "${vote_voter} has voted to ${vote_name} (${vote_count} votes / ${vote_required} needed)"
#define DEFAULT_PASSTEXT "Vote to ${vote_name} has passed"
#define DEFAULT_FAILTEXT "Vote to ${vote_name} has failed"

// limits
#define MAX_VOTES 32
#define MAX_VARIABLES 8
#define FIELD_MAX 128

// additional constants
#define MENU_YES 5
#define MENU_NO 6
#define ELIGIBLE 0
#define INELIGIBLE_REASON_CLIENT 1
#define INELIGIBLE_REASON_AUTH 2
#define INELIGIBLE_REASON_VOTED 3
#define INELIGIBLE_REASON_TEAM 4

// convars
ConVar CvarConfigPath;
ConVar CvarEnable;

// plugin config
int Enable;
char ConfigPath[PLATFORM_MAX_PATH];

// configured votes
StringMap Votes_TriggerMap; // maps trigger -> vote index
float Votes_Ratio[MAX_VOTES];
char Votes_Name[MAX_VOTES][FIELD_MAX];
char Votes_Trigger[MAX_VOTES][FIELD_MAX];
char Votes_VoteText[MAX_VOTES][FIELD_MAX];
char Votes_PassText[MAX_VOTES][FIELD_MAX];
char Votes_FailText[MAX_VOTES][FIELD_MAX];
char Votes_Arguments[MAX_VOTES][FIELD_MAX];
char Votes_Command[MAX_VOTES][FIELD_MAX];
float Votes_Duration[MAX_VOTES];
float Votes_Cooldown[MAX_VOTES];
int Votes_LastInvoked[MAX_VOTES]; // timestamp
int Votes_Count; // number of votes registered

// current vote state
int CurrentVote_Index = -1;
int CurrentVote_NumVotesYes = 0;
int CurrentVote_NumVotesNo = 0;
char CurrentVote_Arguments[MAX_VARIABLES][FIELD_MAX];
Handle CurrentVote_Timer;
StringMap CurrentVote_Voters;
StringMap CurrentVote_Menus;

// parsing nonsense
Regex ArgSpecRegex;
int ParseDepth;

public void OnPluginStart() {
    // init config
    AutoExecConfig_SetCreateDirectory(true);
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetFile("plugin_customvotes");
    CvarEnable = AutoExecConfig_CreateConVar(CVAR_ENABLE, "0", "enable (1) or disable (0) the plugin");
    CvarConfigPath = AutoExecConfig_CreateConVar(CVAR_CONFIG, "", "path to votes configuration file");
    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();

    // init cmds
    RegAdminCmd(CMD_RELOAD, CmdReload, ADMFLAG_GENERIC, "reload customvotes config");

    // init hooks
    HookConVarChange(CvarConfigPath, OnPathChange);
    HookConVarChange(CvarEnable, OnEnableChange);
    HookEvent("player_team", OnTeamChange);

    // init objects
    ArgSpecRegex = new Regex("([a-zA-Z0-9_]+)(:[a-z]+)?(=.+)?", PCRE_EXTENDED);
    Votes_TriggerMap = new StringMap();
    CurrentVote_Voters = new StringMap();

    // initialize configuration
    Enable = CvarEnable.IntValue;
    CvarConfigPath.GetString(ConfigPath, PLATFORM_MAX_PATH);
    ReloadConfig();
}

// cvar handling

void OnEnableChange(ConVar convar, const char[] oldval, const char[] newval) {
    int prev = Enable;
    Enable = CvarEnable.IntValue;
    if (Enable && !prev) {
        RegisterTriggers();
    }
    else if (!Enable && prev) {
        UnregisterTriggers();
    }
}

void OnPathChange(ConVar convar, const char[] oldval, const char[] newval) {
    CvarConfigPath.GetString(ConfigPath, PLATFORM_MAX_PATH);
    ReloadConfig();
}

// cmd handling

Action CmdReload(int client, int argc) {
    ReloadConfig();
}

// trigger registration

void RegisterTriggers() {
    for (int i = 0; i < Votes_Count; ++i) {
        if (!Votes_TriggerMap.SetValue(Votes_Trigger[i], i, true)) {
            LogMessage("error: failed to store trigger index - plugin may be in bad state");
            return;
        }
        if (!AddCommandListener(VoteCommandHandler, Votes_Trigger[i])) {
            LogMessage("error: failed to register command - plugin may be in bad state");
            return;
        }
    }
    LogMessage("info: enabled vote command listeners");
}

void UnregisterTriggers() {
    for (int i = 0; i < Votes_Count; ++i) {
        RemoveCommandListener(VoteCommandHandler, Votes_Trigger[i]);
    }
    Votes_TriggerMap.Clear();
    LogMessage("info: removed vote command listeners");
}

// config handling

void ReloadConfig() {
    UnregisterTriggers();

    Votes_Count = 0;
    ParseDepth = 0;
    
    int line;
    int col;
    SMCParser parser = new SMCParser();
    parser.OnEnterSection = Parse_NewSection;
    parser.OnLeaveSection = Parse_EndSection;
    parser.OnKeyValue = Parse_KV;
    SMCError err = parser.ParseFile(ConfigPath, line, col);

    if (err != SMCError_Okay) {
        LogMessage("error: customvotes config failed to parse at line %d col %d", line, col);
        Votes_Count = 0;
        return;
    }

    LogMessage("info: %d custom votes parsed", Votes_Count);

    if (Enable) {
        RegisterTriggers();
    }
}

SMCResult Parse_NewSection(SMCParser smc, const char[] name, bool quoted) {
    if (ParseDepth++ == 0) {
        return SMCParse_Continue;
    }

    if (Votes_Count >= MAX_VOTES) {
        LogMessage("error: too many custom votes, a maximum of %d is supported", MAX_VOTES);
        return SMCParse_HaltFail;
    }

    // set name
    strcopy(Votes_Name[Votes_Count], FIELD_MAX, name);
    if (strlen(Votes_Name[Votes_Count]) <= 0) {
        LogMessage("error: vote cannot have empty name (section %d)", Votes_Count + 1);
        return SMCParse_HaltFail;
    }
    
    // default/init fields
    Votes_Trigger[Votes_Count][0] = '\0';
    Votes_Arguments[Votes_Count][0] = '\0';
    Votes_Command[Votes_Count][0] = '\0';
    Votes_Ratio[Votes_Count] = DEFAULT_RATIO;
    Votes_Duration[Votes_Count] = DEFAULT_DURATION;
    Votes_Cooldown[Votes_Count] = DEFAULT_COOLDOWN;
    strcopy(Votes_VoteText[Votes_Count], FIELD_MAX, DEFAULT_VOTETEXT);
    strcopy(Votes_PassText[Votes_Count], FIELD_MAX, DEFAULT_PASSTEXT);
    strcopy(Votes_FailText[Votes_Count], FIELD_MAX, DEFAULT_FAILTEXT);
    Votes_LastInvoked[Votes_Count] = 0;
    
    return SMCParse_Continue;
}

SMCResult Parse_EndSection(SMCParser smc) {
    if (--ParseDepth == 0) {
        return SMCParse_Continue;
    }

    int errors = 0;

    if (strlen(Votes_VoteText[Votes_Count]) <= 0) {
        LogMessage("error: vote_text for '%s' is empty", Votes_Name[Votes_Count]);
        ++errors;
    }
    if (strlen(Votes_PassText[Votes_Count]) <= 0) {
        LogMessage("error: pass_text for '%s' is empty", Votes_Name[Votes_Count]);
        ++errors;
    }
    if (strlen(Votes_FailText[Votes_Count]) <= 0) {
        LogMessage("error: fail_text for '%s' is empty", Votes_Name[Votes_Count]);
        ++errors;
    }
    if (strlen(Votes_Trigger[Votes_Count]) <= 0) {
        LogMessage("error: trigger for '%s' is empty", Votes_Name[Votes_Count]);
        ++errors;
    }
    if (strlen(Votes_Command[Votes_Count]) <= 0) {
        LogMessage("error: command for '%s' is empty", Votes_Name[Votes_Count]);
        ++errors;
    }
    if (Votes_Ratio[Votes_Count] <= 0) {
        LogMessage("error: ratio %f for '%s' is invalid", Votes_Ratio[Votes_Count], Votes_Name[Votes_Count]);
        ++errors;
    }

    // note that due to "sourcepawn is dumb" reasons, validation of the arguments param is deferred until time of use

    if (errors > 0) {
        return SMCParse_HaltFail;
    }

    ++Votes_Count;
    return SMCParse_Continue;
}

SMCResult Parse_KV(SMCParser smc, const char[] key, const char[] val, bool kq, bool vq) {
    if (strcmp(key, "vote_text", false) == 0) {
        strcopy(Votes_VoteText[Votes_Count], FIELD_MAX, val);
    }
    else if (strcmp(key, "pass_text", false) == 0) {
        strcopy(Votes_PassText[Votes_Count], FIELD_MAX, val);
    }
    else if (strcmp(key, "fail_text", false) == 0) {
        strcopy(Votes_FailText[Votes_Count], FIELD_MAX, val);
    }
    else if (strcmp(key, "trigger", false) == 0) {
        strcopy(Votes_Trigger[Votes_Count], FIELD_MAX, val);
    }
    else if (strcmp(key, "arguments", false) == 0) {
        strcopy(Votes_Arguments[Votes_Count], FIELD_MAX, val);
    }
    else if (strcmp(key, "command", false) == 0) {
        strcopy(Votes_Command[Votes_Count], FIELD_MAX, val);
    }
    else if (strcmp(key, "ratio", false) == 0) {
        Votes_Ratio[Votes_Count] = StringToFloat(val);
    }
    else if (strcmp(key, "duration", false) == 0) {
        Votes_Duration[Votes_Count] = StringToFloat(val);
    }
    else if (strcmp(key, "cooldown", false) == 0) {
        Votes_Cooldown[Votes_Count] = StringToFloat(val);
    }
    else {
        LogMessage("error: unhandled config key '%s' in section '%s'", key, Votes_Name[Votes_Count]);
        return SMCParse_HaltFail;
    }
    return SMCParse_Continue;
}

// handle vote triggers

Action VoteCommandHandler(int client, const char[] command, int argc) {
    int index;
    if (!Votes_TriggerMap.GetValue(command, index)) {
        LogMessage("error: client attempted command '%s' which is hooked but not indexed - notify the developer", command);
        ReplyToCommand(client, "Command %s is not available at this time", command);
        return Plugin_Continue;
    }

    // check that a vote is not already in progress
    if (CurrentVote_Index >= 0) {
        ReplyToCommand(client, "A vote is already in progress");
        return Plugin_Continue;
    }

    // check that the vote is not in cooldown
    // note: 2038 problem here probably
    int current_time = GetTime();
    int time_since_vote = current_time - Votes_LastInvoked[index];
    int cooldown_remaining = RoundToCeil(Votes_Cooldown[index] - time_since_vote);
    if (cooldown_remaining > 0) {
        ReplyToCommand(client, "This vote occurred recently and cannot be called again for %d seconds", cooldown_remaining);
        return Plugin_Continue;
    }

    // handle arguments
    if (!ProcessArguments(client, index, argc)) {
        return Plugin_Continue;
    }

    // set up state and create ui
    InitiateVote(client, index);

    return Plugin_Continue;
}

bool ProcessArguments(int client, int index, int argc) {
    char arg_specs[MAX_VARIABLES][FIELD_MAX];
    int num_args = ExplodeString(Votes_Arguments[index], ",", arg_specs, MAX_VARIABLES, FIELD_MAX, false);
    if (argc > num_args) {
        ReplyToCommand(client, "This command only takes %d arguments, but %d were supplied", num_args, argc);
        return false;
    }
    for (int i = 0; i < num_args; ++i) {
        if (!ProcessArgument(client, arg_specs, i, argc)) {
            return false;
        }
    }
    return true;
}

bool ProcessArgument(int client, const char arg_specs[MAX_VARIABLES][FIELD_MAX], int argi, int argc) {
    char field_name[FIELD_MAX];
    bool has_type;
    char value_type[FIELD_MAX];
    bool has_default;
    char value_default[FIELD_MAX];

    if (!ParseArgumentSpec(arg_specs[argi], field_name, value_type, has_type, value_default, has_default)) {
        LogMessage("error: argument spec '%s' is invalid", arg_specs[argi]);
        ReplyToCommand(client, "There is an error with the voting configuration. Tell an admin!");
        return false;
    }

    if (argi < argc) {
        GetCmdArg(argi + 1, CurrentVote_Arguments[argi], FIELD_MAX);
        if (has_type && !ValidateArgument(client, value_type, CurrentVote_Arguments[argi])) {
            ReplyToCommand(client, "Argument '%s' is not a valid %s", CurrentVote_Arguments[argi], value_type);
            return false;
        }
    }
    else if(has_default) {
        strcopy(CurrentVote_Arguments[argi], FIELD_MAX, value_default);
    }
    else {
        ReplyToCommand(client, "Missing a required argument: %s", field_name);
        return false;
    }

    return true;
}

bool ParseArgumentSpec(const char arg_spec[FIELD_MAX], char field_name[FIELD_MAX], char value_type[FIELD_MAX], bool& has_type, char value_default[FIELD_MAX], bool& has_default) {
    char temp[FIELD_MAX];

    if (ArgSpecRegex.Match(arg_spec) < 0) {
        return false;
    }

    if (!ArgSpecRegex.GetSubString(1, field_name, FIELD_MAX, 0)) {
        return false;
    }

    if ((has_type = ArgSpecRegex.GetSubString(2, temp, FIELD_MAX, 0))) {
        strcopy(value_type, FIELD_MAX, temp[1]);
    }

    if ((has_default = ArgSpecRegex.GetSubString(3, temp, FIELD_MAX, 0))) {
        strcopy(value_default, FIELD_MAX, temp[1]);
    }

    return true;
}

bool ValidateArgument(int client, const char value_type[FIELD_MAX], const char value[FIELD_MAX]) {
    if (strcmp(value_type, "target", false) == 0) {
        if (FindTarget(client, value, true, false) < 0) {
            return false;
        }
    }
    else if(strcmp(value_type, "integer", false) == 0) {
        int dummy;
        if (StringToIntEx(value, dummy) != strlen(value)) {
            return false;
        }
    }
    else if (strcmp(value_type, "number", false ) == 0) {
        float dummy;
        if (StringToFloatEx(value, dummy) != strlen(value)) {
            return false;
        }
    }
    else {
        LogMessage("warning: ignoring unknown validation type '%s'", value_type);
    }

    return true;
}

// vote states

void ShowVoteToClient(int client) {
    char client_auth[FIELD_MAX];
    if (!GetClientAuthKey(client, client_auth)) {
        return;
    }

    Menu menu = new Menu(ReceiveClientVote);
    menu.RemoveAllItems();

    if (// add dummy entries in the first 5 slots
        !menu.AddItem("", "", ITEMDRAW_DISABLED) ||
        !menu.AddItem("", "", ITEMDRAW_DISABLED) ||
        !menu.AddItem("", "", ITEMDRAW_DISABLED) ||
        !menu.AddItem("", "", ITEMDRAW_DISABLED) ||
        !menu.AddItem("", "", ITEMDRAW_DISABLED) ||

        // actual voting
        !menu.AddItem("Yes", "Yes") ||
        !menu.AddItem("No", "No")) {
        LogMessage("error: failed to create menu for client %d", client);
    }

    int clients[1];
    clients[0] = client;
    menu.DisplayVote(clients, 1, 9999);
    
    CurrentVote_Menus.SetValue(client_auth, menu);
}

void InitiateVote(int client, int index) {
    CurrentVote_Index = index;
    CurrentVote_NumVotesYes = 0;
    CurrentVote_NumVotesNo = 0;
    CurrentVote_Voters.Clear();
    // note args have already been parsed

    // start timeout timer if necessary
    if (Votes_Duration[index] >= 0) {
        CurrentVote_Timer = CreateTimer(Votes_Duration[index], VoteTimeout);
    } else {
        CurrentVote_Timer = null;
    }

    int clients[MAXPLAYERS];
    int numclients = CollectEligibleVoters(clients);
    for (int i = 0; i < numclients; ++i) {
        if (client != i) {
            ShowVoteToClient(i);
        }
    }

    ClientVoted(client, true);
}

void RemoveVoteFromClient(int client) {
    char client_auth[FIELD_MAX];
    if (!GetClientAuthKey(client, client_auth)) {
        return;
    }

    Menu menu;
    if (CurrentVote_Menus.GetValue(client_auth, menu)) {
        menu.Cancel();
        CurrentVote_Menus.Remove(client_auth);
        CloseHandle(menu);
    }
}

int ReceiveClientVote(Menu menu, MenuAction action, int client, int selection) {
    if (action != MenuAction_Select) {
        return 0;
    }

    char client_auth[FIELD_MAX];
    if (!GetClientAuthKey(client, client_auth)) {
        return 0;
    }

    Menu known_menu;
    if (!CurrentVote_Menus.GetValue(client_auth, known_menu)) {
        return 0;
    }

    if (menu != known_menu) {
        return 0;
    }

    if (selection != MENU_YES && selection != MENU_NO) {
        return 0;
    }

    RemoveVoteFromClient(client);
    ClientVoted(client, selection == MENU_YES);

    return 0;
}

Action VoteTimeout(Handle timer) {
    EndVoteWithFailure();
}

void EndVoteWithSuccess() {
    MessageVoteCompletion(true);
    ExecuteCommand();
    ResetVoteState();
}

void EndVoteWithFailure() {
    MessageVoteCompletion(false);
    ResetVoteState();
}

void ResetVoteState() {
    CurrentVote_Index = -1;
    CurrentVote_NumVotesYes = 0;
    CurrentVote_NumVotesNo = 0;

    if (CurrentVote_Timer != null) {
        KillTimer(CurrentVote_Timer);
        CurrentVote_Timer = null;
    }

    char tmp[FIELD_MAX];
    StringMapSnapshot keys = CurrentVote_Menus.Snapshot();
    for (int i = 0; i < keys.Length; ++i) {
        Menu menu;
        keys.GetKey(i, tmp, FIELD_MAX);
        if (CurrentVote_Menus.GetValue(tmp, menu)) {
            menu.Cancel();
            CloseHandle(menu);
        }
    }
    CloseHandle(keys);

    CurrentVote_Voters.Clear();
    CurrentVote_Menus.Clear();
}

bool CheckVoteCompletion() {
    int num_clients = CountElectorate();
    if (CurrentVote_NumVotesYes >= RoundToCeil(Votes_Ratio[CurrentVote_Index] * num_clients)) {
        EndVoteWithSuccess();
        return true;
    }
    if (CurrentVote_NumVotesNo >= RoundToCeil((1.0 - Votes_Ratio[CurrentVote_Index]) * num_clients))  {
        EndVoteWithFailure();
        return true;
    }
    return false;
}

void ClientVoted(int client, bool yes) {
    char client_auth[FIELD_MAX];
    if (!GetClientAuthKey(client, client_auth)) {
        return;
    }

    if (CurrentVote_Index < 0) {
        ReplyToCommand(client, "No vote is in progress");
        return;
    }

    int reason;
    if (!ClientIsEligibleToVote(client, reason)) {
        switch(reason) {
            case INELIGIBLE_REASON_CLIENT: {
                ReplyToCommand(client, "Vote not counted because you are not logged in");
            }
            case INELIGIBLE_REASON_AUTH: {
                ReplyToCommand(client, "Vote not counted because you are not logged in");
            }
            case INELIGIBLE_REASON_VOTED: {
                ReplyToCommand(client, "You have already voted");
            }
            case INELIGIBLE_REASON_TEAM: {
                ReplyToCommand(client, "Spectators cannot vote");
            }
            default: {
                ReplyToCommand(client, "Something went wrong");
            }
        }
        return;
    }

    CurrentVote_Voters.SetValue(client_auth, yes);

    if (yes) {
        CurrentVote_NumVotesYes += 1;
    }
    else {
        CurrentVote_NumVotesNo += 1;
    }

    MessageVoteProgress(client, yes);
    CheckVoteCompletion();
}

// player management

int CountElectorate() {
    // exclude spectators from voting
    // TODO: support for other games than csgo
    return GetTeamClientCount(CS_TEAM_T) + GetTeamClientCount(CS_TEAM_CT);
}

bool ClientHasVoted(int client, bool& vote) {
    char client_auth[FIELD_MAX];
    if (!GetClientAuthKey(client, client_auth)) {
        return false;
    }
    return ClientAuthHasVoted(client_auth, vote);
}

bool ClientHasVoteActive(int client) {
    char client_auth[FIELD_MAX];
    if (!GetClientAuthKey(client, client_auth)) {
        return false;
    }

    Menu dummy;
    return CurrentVote_Menus.GetValue(client_auth, dummy);
}

bool ClientAuthHasVoted(char client_auth[FIELD_MAX], bool& vote) {
    return CurrentVote_Voters.GetValue(client_auth, vote);
}

bool GetClientAuthKey(int client, char client_auth[FIELD_MAX]) {
    return GetClientAuthId(client, AuthId_Engine, client_auth, FIELD_MAX, true);
}

bool ClientIsEligibleToVote(int client, int& reason) {
    if (!IsClientInGame(client) || IsFakeClient(client)) {
        reason = INELIGIBLE_REASON_CLIENT;
        return false;
    }

    char client_auth[FIELD_MAX];
    if (!GetClientAuthKey(client, client_auth)) {
        reason = INELIGIBLE_REASON_AUTH;
        return false;
    }

    bool dummy;
    if (ClientAuthHasVoted(client_auth, dummy)) {
        reason = INELIGIBLE_REASON_VOTED;
        return false;
    }

    // TODO: support for other games than csgo
    int team = GetClientTeam(client);
    if (team != CS_TEAM_T && team != CS_TEAM_CT) {
        reason = INELIGIBLE_REASON_TEAM;
        return false;
    }

    reason = ELIGIBLE;
    return true;
}

int CollectEligibleVoters(int[] clients) {
    int count = 0;
    int dummy;
    for (int i = 1; i < MAXPLAYERS; ++i) {
        if (ClientIsEligibleToVote(i, dummy)) {
            clients[count++] = i;
        }
    }
    return count;
}

public void OnClientDisconnect(int client) {
    if (CurrentVote_Index >= 0) {
        CheckVoteCompletion();
    }
}

public Action OnTeamChange(Event event, const char[] name, bool dontBroadcast) {
    if (CurrentVote_Index < 0) {
        return Plugin_Continue;
    }

    int dummy;
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    bool active = ClientHasVoteActive(client);
    bool eligible = ClientIsEligibleToVote(client, dummy);

    if (eligible) {
        if (!active) {
             // client is now eligible to vote, give them the menu
             ShowVoteToClient(client);
        }
    }
    else {
        if (active) {
            // client is no longer eligible to vote, take away the menu
            RemoveVoteFromClient(client);
        }

        bool vote;
        if (ClientHasVoted(client, vote)) {
            // un-count their vote
            if (vote) {
                --CurrentVote_NumVotesYes;
            }
            else {
                --CurrentVote_NumVotesNo;
            }
        }

        // a client becoming ineligible can cause the vote to complete
        CheckVoteCompletion();
    }

    return Plugin_Continue;
}

// variable handling

void ReplaceVariablesInString(char string[FIELD_MAX], char[] player) {
    char tmp[FIELD_MAX];

    // replace custom variables
    char arg_specs[MAX_VARIABLES][FIELD_MAX];
    int num_variables = ExplodeString(Votes_Arguments[CurrentVote_Index], ",", arg_specs, MAX_VARIABLES, FIELD_MAX, false);
    for (int i = 0; i < num_variables; ++i) {
        char field_name[FIELD_MAX];
        bool has_type;
        char value_type[FIELD_MAX];
        bool has_default;
        char value_default[FIELD_MAX];
        if (ParseArgumentSpec(arg_specs[i], field_name, value_type, has_type, value_default, has_default)) {
            Format(tmp, FIELD_MAX, "${%s}", field_name);
            ReplaceString(string, FIELD_MAX, tmp, CurrentVote_Arguments[i]);
        }
    }

    // replace predefined variables
    ReplaceString(string, FIELD_MAX, "${vote_voter}", player);
    ReplaceString(string, FIELD_MAX, "${vote_name}", Votes_Name[CurrentVote_Index]);
    Format(tmp, FIELD_MAX, "%d", CurrentVote_NumVotesYes);
    ReplaceString(string, FIELD_MAX, "${vote_count}", tmp);
    Format(tmp, FIELD_MAX, "%d", RoundToCeil(Votes_Ratio[CurrentVote_Index] * CountElectorate()));
    ReplaceString(string, FIELD_MAX, "${vote_required}", tmp);
}

void ExecuteCommand() {
    char command[FIELD_MAX];
    strcopy(command, FIELD_MAX, Votes_Command[CurrentVote_Index]);
    char name[1];
    ReplaceVariablesInString(command, name);
    ServerCommand(command);
}

// chat messages

void MessageVoteProgress(int client, bool yes) {
    if (yes) {
        char name[FIELD_MAX];
        GetClientName(client, name, FIELD_MAX);

        char message[FIELD_MAX];
        strcopy(message, FIELD_MAX, Votes_VoteText[CurrentVote_Index]);

        ReplaceVariablesInString(message, name);
        PrintToChatAll(message);
    }
}

void MessageVoteCompletion(bool yes) {
    char message[FIELD_MAX];
    char name[1];
    if (yes) {
        strcopy(message, FIELD_MAX, Votes_PassText[CurrentVote_Index]);
    }
    else {
        strcopy(message, FIELD_MAX, Votes_FailText[CurrentVote_Index]);
    }
    ReplaceVariablesInString(message, name);
    PrintToChatAll(message);
}

