# [Uber on Slack][uberslacklink]

* An Uber & Slack Integration API
* Built by App Academy students in the August 2015 cohort
* Refer to [the live site][uberslacklink] for currently available commands & usage

## Overview

Uber on Slack enables Slack users to hail Uber rides directly from their chat client with a command-line type interface. By using [slash commands][slashlink] from the Slack API, Uber on Slack allows the user to type in commands to hail an UberX ride, get ETAs, and more!

[slashlink]: https://api.slack.com/slash-commands
[uberslacklink]: https://uberonslack.com


## Usage

All commands will follow the following format:
```
/uber [command] [extra parameters]
```

You'll be asked to link your Slack and Uber accounts using the OAuth protocol the first time you use an /uber command.  After that, your next ride is just an `/uber` away!

#### Hailing a Ride
To hail a ride, enter a 'ride' command in your Slack chat in the following format:
```
/uber ride [pickup address] to [destination address]
```

This can handle a variety of address formats:
```
/uber ride 1061 market st San Francisco to 24 willie mays plaza
/uber ride 1061 Market St. SF to 24 Willie Mays Plaza
/uber ride 1061 market street san francisco to 24 willie mays plaza san francisco
```

Uber will look for an available UberX near your origin address.  You may check up on the status of this request with an `/uber status` command. Once a driver is on their way, you'll receive a confirmation.  If surge pricing is in effect, the surge multiplier will be shown first, and you can `/uber accept` to get your ride. Cancelling rides is as easy as typing `/uber cancel` into your Slack client. Sharing ride details is as easy as using an `/uber share` command and sharing the resulting hyperlink from the Slack bot.

#### Getting Fare and Time Estimates
To receive a fair and time estimate to a particular destination, use the following entry format:
```
/uber estimate to [destination address]
```

#### Uber Vehicles
To see a list of Uber products available for your address:
```
/uber products [destination address]
```

#### Help
A help manual is available with the 'help' command:
```
/uber help
```

#### To-Dos / Forthcoming Features
- [X] Get fare estimates for your trip with `/uber fares [pickup address] [destination]`
- [ ] Echo command and resolved geographic information back
- [X] Canceling ride requests from Slack using `/uber cancel`
- [ ] Specifying which Uber service to hail in the format `/uber ride [service] [pickup address] [destination]`
