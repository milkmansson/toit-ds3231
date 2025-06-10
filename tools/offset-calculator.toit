import esp32 show set-real-time-clock deep-sleep
import ds3231 show Ds3231
import gpio

import ntp
import mqtt
import net

/*
WARNING: To use this program effectively you have to set the
parameters apropriatelly. You need an MQTT client like EMQTX
or MQTT-Explorer to see the results.

The program applies automatically the offset to the module.
Be aware that whithout power, removing or
replacing the battery, will reset all settings.

Only a ESP32x (with stable wifi) and DS3231 is needed. ESP modules with lipo socket are preferred (To avoid interruptions).
Typically after after 12-24 h the program applies an aging factor. However usually, the correction does not eliminate the systematic drift entirelly. After the
aging factor is applied the module will reset and start again.
After a few days the process is complete. The good news is you can have many ESP modules
running in parallel. If you have more than one running modules,
put a labe with the toit name in every ESP module.
The MQTT topic contains the IP and it is very easy with "toit scan" to find the correct
module.

Some ppm error values : 1.2 0.6 0.2 etc

Use the SN chips. The MEMS based are not as accurate.

*/

/** ****** START OF CONFIGURATION ****** */

/** Your initials or something unique, mainly useful for public mqtt servers.
Set it only once. Appears as part of the mqtt topic */
ID ::= "xy"

/*
Use a LAN NTP server if you have one
I use "chrony" on a debian server mini pc (with ethernet connection).
The buildin NTP server of openwrt does not seem to have millisecond
accuracy, which is logical (I am not blaming openwrt here) and should
not be used. The chrony is available for openwrt but I have not tested
it. If your Internet connection is not stable, no server can help.
*/
//NTP-SERVER ::= "192.168.5.2"

/*
Works but it is suboptimal. The ntp.accuracy is more than 15ms
(depends on your location) and occasionally 200-500ms !
Of course, more time is required to get acceptable results.
*/
NTP-SERVER ::= "pool.ntp.org"

/**
For "pool.ntp.org" cannot be lower than 20ms.
When using a local NTP server(chrony), you can reduce this: 
--ms=7 with ESP32-C3
and --ms=8-10 with ESP32
esp32-c3 although the cheapest in the family, has superb wifi lag(low)
However I still prefer ESP32 lolin32 due to Lipo socket.
*/
NTP-ERROR-MAX := (Duration --ms=30) // Reduce to 10- for local chrony
/**
You can reduce it a little further, to have better accuracy, when
setting the time to the DS3231 (when the program starts). The first NTP
measurement is the most important (writes the time to RTC), as it affects
the accuracy of the whole experiment. If unsure leave it as is.
NTP-ERROR-MAX-SETUP := NTP-ERROR-MAX - (Duration --ms=2)
*/
NTP-ERROR-MAX-SETUP := NTP-ERROR-MAX

//* The time duration between checks. There is no reason to reduce it */
CHECK-PERIOD ::= (Duration --m=30)

/** See the example "ntp-plus-rtc.toit" for various pinout setups */
// rtc ::= Ds3231 --scl=4 --sda=5 // esp32-c3 luatos core
// for ESP32 Devkit and lolin32/lite the following is convenient.
rtc ::=  Ds3231 --sda=33 --scl=32 --vcc=25 --gnd=26 // the exact reverse is also ok

/**
The MQTT client object. You can use a private server of course.
This one works out of the box, and the truth is, we do not store any
top secret info here.
*/
HOST ::= "test.mosquitto.org"
PORT ::= 1883
client/mqtt.SimpleClient? := null // main->mqtt-setup does the connection

// If you want the reports in local time, put the apropriate value here
// TIMEZONE ::= "EET-2EEST,M3.5.0/3,M10.5.0/4"
TIMEZONE ::= null // for UTC

/** The app is running for days, so an indicator is useful */

// lolin32 lite, buldin LED
// LED-PIN/int? ::= 22
// LED-VALUE/int? ::= 0 // active low

// ESP32 devkit buldin LED
// LED-PIN/int? ::= 2
// LED-VALUE/int? ::= 1 // active high

LED-PIN/int? ::= null // null means no led indicator
LED-VALUE/int? ::= null

/** END OF CONFIGURATION */

TOPIC ::= "rtc/ds3231-$ID/aging-offset-$net.open.address"

main:
  if TIMEZONE != null:
    set-timezone TIMEZONE
  if LED-PIN and LED-VALUE:
    p ::= gpio.Pin LED-PIN --output
    p.set LED-VALUE
  /** sets the system+RTC time from NTP, and returns the accuracy
  of the measurement. */
  ntp-accuracy ::= time-setup
  /** For TLS connections the time must be correct */
  mqtt-setup
  mqtt-pub "Connected to mqtt"
  /** We set the time to the DS3231 chip */
  rtc-setup
  /** running for long enough to find deviations between RTC and NTP */
  calulate-drift ntp-accuracy

/** Sets the system time using NTP. Returns the accuracy of the measurement */
time-setup -> Duration:
  coundown := 4
  while true:
    result := ntp.synchronize --server=NTP-SERVER
    if result:
      if result.accuracy < NTP-ERROR-MAX-SETUP:
        set_real_time_clock (Time.now + result.adjustment) // immediate time fix, not gradual
        print "\nNTP sync done, accuracy=$result.accuracy"
        return result.accuracy
      else:
        print "The accuracy of ntp is bad : $result.accuracy"
        if coundown>0:
          coundown--
        else:
          print "Increasing the error tolerance my 1ms"
          NTP-ERROR-MAX-SETUP += (Duration --ms=1)
    else:
      print "NTP synchronization failed"
    sleep --ms=5000

/** Connects to mqtt, for TLS you have to also setup a certificate */
mqtt-setup:
  while true:
    err := catch :
      if client: client.close
      transport := mqtt.TcpTransport --host=HOST --port=PORT
      c := mqtt.SimpleClient --transport=transport
      options := mqtt.SessionOptions --client-id="offset-$(random)"
      c.start --options=options
      // At this point the client is connected to the broker.
      print "Connected to $HOST:$PORT and will publish results to $TOPIC"
      client = c
      return
    if err:
      print "Cannot connect to broker : err = $err"
    sleep --ms=15_000

/** sends a message to mqtt, handling possible errors */
mqtt-pub payload/string:
  print payload
  if client==null:
    print "Cannot send to mqtt, not connected."
    return
  err := catch:
    client.publish TOPIC payload --retain
  if err:
    print "Cannot publish : err = $err"
    mqtt-setup

/** Sets the system time from NTP and writes to the RTC */
rtc-setup:
  try:
    rtc.set (Duration --us=0) // we set the system time
  finally: | is-exception _ |
    if is-exception:
      mqtt-pub "ERROR writing to the RTC"
  try:
    adj := rtc.get
    print "The rtc has diff $adj from system time"
    // TODO the adj can be used to finetune the final accuracy
  finally: | is-exception _ |
    if is-exception:
      mqtt-pub "ERROR reading the RTC"
  

/** Endless loop, as time passes the difference between NTP and RTC grows */
calulate-drift setup-accuracy:
  start-time := Time.now
  mqtt-pub """
  \nWARNING: the first few measurements are worthless, but we
  print them anyway, to show that the program is working
  """
  sleep --ms=10_000
  aging-offset := null
  try:
    aging-offset = rtc.get-aging-offset
  finally: | is-exception _ |
    if is-exception:
      mqtt-pub "Error communicating with Ds3231. Cannot get rtc aging offset"
  if aging-offset==null:
    throw "Programming error"
  while true:
    result := ntp.synchronize --server=NTP-SERVER
    if result:
      if result.accuracy < NTP-ERROR-MAX:
        rtcadj := null
        try:
          rtcadj = rtc.get
        finally: | is-exception _ |
          if is-exception:
            mqtt-pub "Cannot get rtc aging offset"
        if rtcadj==null:
          throw "Programming error"
        diff ::= rtcadj - result.adjustment
        time-passed ::= start-time.to Time.now
        ppm ::= 1.0*1e6*diff.in-us/time-passed.in-us
        ppm-error ::= 1.0*1e6*(result.accuracy.in-us+setup-accuracy.in-us)/time-passed.in-us
        //print "$diff.in-us $time-passed.in-us $result.accuracy.in-us $time-passed.in-us"
        offs:= (ppm*10+0.5).to-int
        now ::= Time.now + result.adjustment
        loctime ::= now.local.stringify[..19]
        runtime ::= start-time.to now
        runtime-h-m ::= "\"$(runtime.in-h)h$(runtime.in-m%60)m\""
        next-measuremet ::= (now+CHECK-PERIOD).local.stringify[..19]
        msg := """{
  "TimeNow":"$loctime",
  "Runtime":$runtime-h-m,
  "Next Measurement":"$next-measuremet",
  "DS3231 SetupTime accuracy":"$(setup-accuracy.in-ms) ms",
  "NTP accuracy":"$(result.accuracy.in-ms) ms",
  "Time Keeping Accuracy":"$(%0.2f ppm) ppm",
  "Accuracy Uncertainty":"+/- $(%0.2f ppm-error) ppm",
  "IP-address":"$net.open.address",
  "Stored Aging Offset":$aging-offset
}"""
        mqtt-pub msg

        if ( (2*ppm-error) < ppm.abs) and (ppm.abs>0.07): // and (ppm-error<0.5):
          write-offset := offs+aging-offset
          try:
            rtc.set-aging-offset write-offset
          finally: | is-exception _ |
            if is-exception:
              mqtt-pub "Cannot set aging offset"
          deep-sleep
            Duration --s=10 // restart the module
        sleep CHECK-PERIOD
      else:
        print "Bad NTP accuracy : $result.accuracy"
        // we want a result, so we retry soon
        sleep
          Duration --s=10
    else:
      print "NTP synchronization failed"
      sleep (Duration --s=10)
