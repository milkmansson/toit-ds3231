import gpio
import i2c
import serial

/**
Driver for the DS3231 Real Time Clock.
*/
class Ds3231:
  /** The i2c adress of the DS3231 is 0x68 and cannot be changed */
  static I2C-ADDRESS/int ::= 0x68

  static REG-START_/int ::= 0x00  // The first time (seconds) register is at location 0x00.
  static REG-NUM_/int ::= 7       // and we read 7 consequitive reagisters, until (2-digit) years.

  static REG-AGING_/int ::= 0x10 // The aging register location.
  static REG-TEMPERATURE_/int ::= 0x11 // The temp register location
  static REG-CONTROL_/int ::= 0x0E
  static REG-STATUS_/int ::= 0x0F
  

  /**
    For direct register read/write
    
    Use it, if the library does not implement a function.
    In that case you may also consider $set-value-with-mask
  */
  registers/serial.Registers? := null

  /**
  The I2C bus.
  
  Null, if not allocated by this class.
  Kept public in case you want to use another i2c device
  for example the AT24C32 EEPROM (on the blue DS3231 boards)
  */
  bus/i2c.Bus? := null
  /** The sda-pin. Null, if not allocated by this class. */
  sda_/gpio.Pin? := null
  /** The scl-pin. Null, if not allocated by this class. */
  scl_/gpio.Pin? := null
  /** The vcc pin, if specified. */
  vcc_/gpio.Pin? := null
  /** The gnd pin, if specified. */
  gnd_/gpio.Pin? := null

  /**
  Creates a Ds3231 instance, given a serial.Device object
  */
  constructor device/serial.Device :
    registers = device.registers

  /**
  Variant of $(constructor device).

  Convenience function to build an i2s bus/device during construction.

  If given, $vcc/$gnd are initialized as output pins with the corresponding levels.
    This simplifies the Ds3231 cabling, and allows to save power when the ESP32 goes
    to sleep.
  */
  constructor
      --sda/int
      --scl/int
      --vcc/int? = null
      --gnd/int? = null :
    try:
      /** will become true if vcc or gnd are GPIO pins */
      gpio-power := false
      /** The vcc and gnd are the first to configure,
      to allow the module to power up and communicate with i2c. */
      if vcc and vcc >= 0:
        vcc_ = gpio.Pin vcc --output
        vcc_.set 1
        gpio-power = true
      if gnd and gnd >= 0:
        gnd_ = gpio.Pin gnd --output
        gnd_.set 0
        gpio-power = true
      if gpio-power:
        // Gives some time for the DS3231 to power up. Not sure is needed.
        sleep --ms=5
      sda_ = gpio.Pin sda
      scl_ = gpio.Pin scl
      bus = i2c.Bus --sda=sda_ --scl=scl_
      device := bus.device I2C-ADDRESS
      registers = device.registers

    finally: | is-exception _ |
      if is-exception:
        if bus: bus.close
        if sda_: sda_.close
        if scl_: scl_.close
        if vcc_: vcc_.close
        if gnd_: gnd_.close

  /** Closes this driver. */
  close -> none:
    if bus:
      bus.close
      bus = null
    if sda_:
      sda_.close
      sda_ = null
    if scl_:
      scl_.close
      scl_ = null
    if vcc_:
      vcc_.close
      vcc_ = null
    if gnd_:
      gnd_.close
      gnd_ = null

  /**
  Reads the time from the Ds3231 chip, and returns the adjustment.

  If $wait-sec-change is false the function returns immediately but can have a time
    error of up to 1 second.
  If $wait-sec-change is true (the default), this function can block up to 1 sec but
    the adjustment is accurate to about 1 ms.
  */
  get -> Duration
      --wait-sec-change/bool = true
      --allow-wrong-time/bool = false:
    tstart := Time.now
    rtctime/Time? := null
    if wait-sec-change:
      v := registers.read-u8 REG-START_
      while true:
        yield
        v1 := registers.read-u8 REG-START_
        if v != v1:
          break
    /** The time is read just when the seconds register (address 0x00)
    goes to the next second. */
    rtctime = this.get_ 
    adjustment := Time.now.to rtctime
    if not allow-wrong-time and rtctime.utc.year < 2025:
      throw "DS3231_TIME_IS_INVALID"
    return adjustment

  /**
  Sets the RTC time to Time.now+adjustment.

  See $get for the meaning of $wait-sec-change and $allow-wrong-time.
  */
  set adjustment/Duration
      --wait-sec-change/bool=true
      --allow-wrong-time/bool=false -> none :
    adjustment += (Duration --us=2750) // We compensate for the i2c and MCU delays.
    if not allow-wrong-time and (Time.now + adjustment).utc.year < 2025:
      throw "YEAR_LESS_THAN_2025"
    t := Time.now + adjustment
    if wait-sec-change: // Wait until the second changes (for better accuracy).
      s := t.utc.s
      while true:
        yield // allow other tasks to run
        t = Time.now + adjustment
        s1 := t.utc.s
        if s != s1: break
    set_ (Time.now + adjustment)

  get_ -> Time:
    buffer := registers.read-bytes REG-START_ REG-NUM_
    t := []
    buffer.do:
      t.add (bcd2int_ it)
    utc := Time.utc --s=t[0] --m=t[1] --h=t[2] --day=t[4] --month=t[5] --year=(2000 + t[6])
    return utc

  set_ tm/Time -> none :
    u := tm.utc
    // Must be 7 fields, the same as the Ds3231 time keeping registers.
    t := [u.s, u.m, u.h, u.weekday, u.day, u.month, (u.year - 2000)]
    buffer := ByteArray REG-NUM_: int2bcd_ t[it]
    /** We write a byte to reset the countdown timer.
    Without this a full second(1000ms) error often happens */
    registers.write-u8 REG-START_ 0 // resets the countdown timer, any value is OK
    registers.write-bytes REG-START_ buffer // writes the time

  /**
  Sets the aging offset.

  run the "offset-calulator.toit" app to calculate it.
  More info on the README
  The new value will work after the next temp conversion.
  The $offset must satisfy -128 <= $offset <= 127.
  */
  set-aging-offset offset/int -> none:
    if not -128 <= offset <= 127: throw "INVALID_ARGUMENT"
    registers.write-i8 REG-AGING_ offset

  /** 
  Reads the aging offset from the chip.
  
  When first powered it has the value of 0, but if set to a
  different value, it can retain this value as long as it is powered
  or battery backed. */
  get-aging-offset -> int: // useful with "offset-calulator.toit"
    return registers.read-i8 REG-AGING_

  /** internal function, calls $set-value-with-mask with specific
  register and mask */
  set-sqw_ value -> none:
    set-value-with-mask
      --register=0x0e
      --mask=0b000_111_00
      --value=value

  /**
  Sets some bits of the given $register.

  Uses the given $mask to select the bits that should be changed.
  No bits outside the $mask are changed.

  The given $value is applied unshifted (but masked).
  */
  set-value-with-mask --register/int --mask/int --value/int -> none:
    if not ((0 <= register <= 0x12) and (0 <= mask <= 255) and (0 <= value <= 255)):
      throw "PARAMETER_OUT_OF_BOUNDS"
    new-value/int := value
    old-value/int := registers.read-u8 register
    value-to-apply/int := (old-value & ~mask) | (new-value & mask)
    registers.write-u8 register value-to-apply

  /** Equivalent with $enable-sqw-output --frequency=1 */
  enable-sqw-1hz -> none :
    set-sqw_ 0b000_000_00 // RS2->0 RS1->0 INTCN->0
    

  /** Equivalent with $enable-sqw-output --frequency=1000 */
  enable-sqw-1kilohz -> none:
    set-sqw_ 0b000_010_00

  /** Equivalent with $enable-sqw-output --frequency=4000 */
  enable-sqw-4kilohz -> none :
    set-sqw_ 0b000_100_00

  /** Equivalent with $enable-sqw-output --frequency=8000 */
  enable-sqw-8kilohz -> none :
    set-sqw_ 0b000_110_00

  /**
  Enables the given $frequency on the sqw pin.

  The output is open-drain, and it requires pull-up (external or software).

  The $frequency must be one of 1, 1000, 4000, or 8000.
  */
  enable-sqw-output --frequency/int -> none:
    if frequency == 1: set-sqw_ 0b000_000_00 // RS2->0 RS1->0 INTCN->0.
    else if frequency == 1000: set-sqw_ 0b000_010_00
    else if frequency == 4000: set-sqw_ 0b000_100_00
    else if frequency == 8000: set-sqw_ 0b000_110_00
    else: throw "INVALID_FREQUENCY"


  /** Disables the output on the sqw pin. */
  disable-sqw -> none :
    set-sqw_ 0b000_111_00

  /**
  Enables the battery-backed sqw.
  */
  enable-battery-backed-sqw -> none :
    set-value-with-mask --register=0x0e --value=0b0_1_000000 --mask=0x0_1_000000

  /**
  Disables the battery-backed sqw.
  This is the default DS3231 setting.
  */
  disable-battery-backed-sqw -> none :
    set-value-with-mask --register=0x0e --value=0b0_0_000000 --mask=0x0_1_000000

  /** Returns the temperature in celsius.

  The value seems to have 0.25°C accuracy but in fact it can have
  up to 3 degrees error. However with the decimals you can find
  if the temp is going up or down. Tested and working correctly
  with both positive and negative values.
  */
  get-temperature -> float :
    /** (4*temp) is stored as 10-bit 2-complement number
    buf[0] the sign + 7 most significant bits
    buf[1] bits 7 and 8 represent the decimal part 
    the other bits are ignored */
    buf ::= registers.read-bytes REG-TEMPERATURE_ 2
    temp := (buf[0]<<2) | (buf[1]>>6)
    // the temp (32bit integer) now contains the 10-bit value
    if (temp & (1<<9))!=0: // if the 10-bit number is negative
      temp -= (1<<10) // remove 1024
    // else the number is positive and we leave it as is.
    //
    // at this point temp only needs to be divided by 4
    return temp.to-float/4

  /** Forces a temperature conversion. Returns when the operation is
  finished. Usually not needed (happens automatically every 64sec),
  only if you use your DS3231 as a thermometer ! */
  force-temp-conversion -> none:
    CONV ::= (1<<5) // in Control Register
    BSY ::= (1<<2) // in Status Register
    if ((registers.read-u8 REG-STATUS_) & BSY) !=0 : // already in temp conversion mode
      15.repeat:
        if ((registers.read-u8 REG-STATUS_) & BSY) == 0:
          return
        else:
          sleep --ms=10
          // print "BSY"
      throw "TIMEOUT_WAITING_BSY"
    else: // Not BSY flag, we can initiate a Temp Conversion
      // set the CONV bit to 1
      set-value-with-mask --register=REG-CONTROL_ --mask=CONV --value=CONV
      15.repeat:
        if ((registers.read-u8 REG-CONTROL_) & CONV)==0:
          return
        else:
          sleep --ms=10
          //print "CONV"
      throw "TIMEOUT_WAITING_CONV"
   

  /**
  Returns the expected drift. A Time object must be given

  The drift is calculated by assuming a 2ppm error (unless you set a different)
  since the last time the clock is set. The drift is usually smaller, and in some
  cases (high temperature deviations) can be greater. With the aging offset calibrated
  and not very high temperature deviations, this can be significantly lower.
  */
  expected-drift --from-time/Time --ppm/num=2 -> Duration?:
    ppm = ppm * 1.0 // to be sure is float
    t/Time := Time.now
    //if not last-set-time_: return null
    return (from-time.to t) * ppm / 1e6

  /** seconds minutes hours etc. are stored in the DS3231 registers as BCD. */
  static int2bcd_ x/int -> int:
    return (x / 10) * 16 + (x % 10)

  static bcd2int_ x/int -> int:
    return (x / 16) * 10 + (x % 16)
