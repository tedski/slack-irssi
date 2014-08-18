# Slack Irssi Plugin
A plugin to add functionality when dealing with Slack.  See [Slack's website](https://www.slack.com/) for details on what Slack is.

## Usage

There are 3 settings available:

/set slack_token <string>
 * The api token from [https://api.slack.com/]

/set slack_away ON/OFF/TOGGLE
 * manage your slack presence with /away

/set slack_loglines <integer>
 * the number of lines to grab from channel history

# Known issues

The API calls block I/O until they receive a response.  A forked version of this script is forthcoming.
