import ds3231 show *

/*
Scenario:

We have an RTC and we wish to program an alarm.

This method uses a task to watch the alarm trigger register.  Using a pin
interrupt would be the more common method - in a separate example.

Note that the display shows the system time on the ESP32, not the time on
the DS3231.

// rtc ::= Ds3231 --scl=7 --sda=6 --vcc=10 --gnd=3 /* esp32-c3 core with GPIO as vcc and gnd */
// rtc := Ds3231 --sda=25 --scl=26 --vcc=33 --gnd=32 /* Lolin32 lite */
// rtc := Ds3231 --sda=33 --scl=32 --vcc=25 --gnd=26 /* ESP32 Devkit all versions */
// rtc := Ds3231 --sda=35 --scl=36 --vcc=37 --gnd=38 /* S3 devkitC abudance of pins here */

*/

rtc ::= Ds3231 --scl=20 --sda=19 /* esp32-c6 DFrobot Beetle */

main:
  print

  // Create every-minute alarm object - every time the seconds gets to '30':
  minutely := AlarmSpec.every-minute --seconds=30
  print "Hourly alarm is: $minutely ($(minutely.stringify --debug))"

  // Set alarm in the registers:
  rtc.set-alarm 1 minutely
  print "Alarm 1 now set to: $minutely."

  // Set SQW Pin to Interrupt (although we aren't using it in this example):
  rtc.set-sqw-as-interrupt true

  // Enable Alarm 1:
  rtc.enable-alarm 1 true

  // Start task to print a line when it sees the alarm register change.
  task := ::
    while true:
      if rtc.is-alarm-triggered 1:
        print " ** Alarm 1 triggered ** [$(Time.now.local)]"
        rtc.clear-alarm 1
      sleep --ms=1000

  // Start task
  task.call
  return
