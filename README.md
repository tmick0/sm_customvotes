# customvotes

A sourcemod plugin for configurable voting.

## Configuration

### Convars

**sm_customvotes_enable**: 0 to disable, 1 to enable (default 0)

**sm_customvotes_config**: path to the config file, relative to the game root

### Commands

**sm_customvotes_reload**: force reloading the config file

### Vote specification

The config file uses [SMC key-value syntax](https://sm.alliedmods.net/new-api/textparse/SMCParser). Each custom vote has the following fields:

**ratio**: required ratio of yes votes for the vote to pass (optional, default 0.5)

**vote_text**: message to be displayed when the vote is running (template, optional, default "${vote_voter} has voted to ${vote_name} (${vote_count} votes / ${vote_required} needed)")

**pass_text**: message to be displayed when the vote completes with the necessary number of votes (template, optional, default "Vote to ${vote_name} has passed")

**fail_text**: message to be displayed when the vote completes without the necessary number of votes (template, optional, default "Vote to ${vote_name} has failed")

**duration**: length of time (seconds) before voting concludes, special value -1 means unlimited (optional, default -1)

**cooldown**: length of time (seconds) required between attempts to run this vote (optional, default 0)

**trigger**: console command to register to initiate the vote (required)

**arguments**: ordered comma-separated list of arguments to the vote, which define template variables (optional, see syntax in next section)

**command**: console command to execute when the vote passes (template, required)

Additionally, each vote has a name, which comes from the key corresponding to its specification block.

For example:

```
"Votes"
{
  "Stab Stab Zap"
  {
    "ratio" "0.60"
    "trigger" "votestabstabzap"
    "command" "exec custom/foo/bar.cfg"
  }
  "Mute Player"
  {
    "ratio" "0.60"
    "vote_text" "${vote_voter} has voted to mute ${target_name} (${vote_count} votes / ${vote_required} needed)"
    "pass_text" "Vote to mute ${target_name} has passed"
    "duration" "120"
    "cooldown" "240"
    "trigger" "votemute"
    "arguments" "target_name:target"
    "command" "sm_silence ${target_name}"
  }
}
```

### Template syntax

The above fields tagged as *template* accept variable substitutions with the `${var}` syntax.

A number of variables are predefined:

**vote_name**: name of the vote, from the key of its spec block

**vote_count**: number of "yes" votes received

**vote_required**: number of votes required for the measure to pass

**vote_voter**: name of the player whose vote is currently being processed (nominally available only in the context of the *text* template)

The *arguments* field allows parameters to be passed when initiating the vote, which will become variables in that vote's context. The arguments field accepts a comma-separated list of argument specifications of the form `identifier [ ":" type ] [ "=" value ]`,
i.e. a required identifier name followed by two optional fields: a `:`-prefixed *type*, and a `=`-prefixed *value*.

The `identifier` may include alphanumeric and underscore; `type` lowercase alpha, and `value` any character except the comma.

If `type` is specified as one of the below known types, the argument will be validated against one of the following rules before initiating the vote:

- `target`: The argument must identify a single target player (uses [FindTarget](https://sm.alliedmods.net/new-api/helpers/FindTarget))
- `number`: The argument must parse successfully as a float
- `integer`: The argument must parse successfully as an integer

If `value` is specified, the argument is optional. Optional arguments must follow required arguments if both are used.

Examples:

- `target_name:target`: specifies one variable called `target_name`, which must validate as a `target`
- `message=hello world`: specifies one variable called `message`, which defaults to `"hello world"` and has no validation rules
- `duration:number=15.0`: specifies one variable called `duration`, which defaults to `15.0` and must be a number
- `target_name:target,duration:number=15.0`: requires the `target_name` argument as above, and optionally the `duration` argument
