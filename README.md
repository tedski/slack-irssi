# Slack Irssi Plugin
A plugin to add functionality when dealing with Slack.  See [Slack's website](https://www.slack.com/) for details on what Slack is.

## Usage

Use the `/mark` command to mark the current window as read in slack.

On connect to the server, expect the number of lines set in `slack_loglines` to be spewed to each channel you join.

## Configuration

There are 2 settings available:

`/set slack_token <string>`
 * The api token from [https://api.slack.com/]

`/set slack_loglines <integer>`
 * the number of lines to grab from channel history
