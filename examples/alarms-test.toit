import ds3231 show *

/*
Scenario:

We have an RTC and we wish to program an alarm.

This method uses a task to watch the alarm trigger register.  Using a pin
interrupt would be the more common method - in a separate example.

Note that the display shows the system time on the ESP32, not the time on
the DS3231.
*/

// Wiring for the DFRobot FireBeetle 2 ESP32-C6. See the README for other boards.
SDA-PIN ::= 19
SCL-PIN ::= 20

rtc ::= Ds3231 --sda=SDA-PIN --scl=SCL-PIN

main:
  print

  // Create every-minute alarm object - every time the seconds gets to '30':
  minutely := AlarmSpec.every-minute --seconds=30
  print "Minutely alarm is: $minutely ($(minutely.stringify --debug))"

  // Set alarm in the registers:
  rtc.set-alarm 1 minutely
  print "Alarm 1 now set to: $minutely."

  // Set SQW Pin to Interrupt (although we aren't using it in this example):
  rtc.set-sqw-as-interrupt true

  // Enable Alarm 1:
  rtc.enable-alarm 1 true

  // Start a task to print a line when it sees the alarm register change.
  task::
    while true:
      if rtc.is-alarm-triggered 1:
        print " ** Alarm 1 triggered ** [$(Time.now.local)]"
        rtc.clear-alarm 1
      sleep --ms=1000
