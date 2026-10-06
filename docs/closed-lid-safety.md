# Running a MacBook Pro with the lid closed: what the evidence says

Researched October 2026 for 14/16-inch Apple Silicon MacBook Pros (with fans). Bottom line: on a stand with good airflow this is low risk. Apple supports closed-lid running in its own clamshell mode and sets no thermal limits for it. Most of the evidence is indirect, so treat it as "no known harm", not "proven harmless".

## Screen: low risk (evidence moderate)
- Closing the lid turns the internal panel off (AppleClamshellState = Yes), so the panel itself adds no heat and wears no faster.
- The display does run warmer, because the hinge exhaust blows toward it. Forum reports say 5 to 10 °C warmer under heavy load. Nobody has reported damage from it.
- Staingate (coating peeling on 2012–2015 Retina screens) and the keyboard imprints still seen on M-series screens come from skin oils and keyboard contact, not heat. They depend on closing the lid at all, not on how long the Mac runs closed. Wipe the keyboard before closing for long sessions, and never close the lid on anything (Apple: camera covers thicker than 0.1 mm can crack the screen).

## Cooling: fine with an open stand (evidence moderate to strong)
- Air comes in along the lower side edges and the bottom, and leaves through the hinge. A closed lid blocks neither.
- Fans and throttling work exactly as with the lid open. The script never touches them.
- Upright or flat: no measured difference found. Upright leaves the side and bottom intakes fully open. Make sure the stand doesn't cover the hinge.
- Apple's operating range is 10–35 °C room temperature.

## Battery: no specific harm known (evidence indirect)
- The risk is heat, not the lid. Apple says battery temperatures above 35 °C can permanently reduce capacity, and charging while hot makes it worse.
- Optimized charging is unaffected by the lid.
- The watchdog stops at 45 °C by default. Use `--max-temp 40` for long charging sessions, or `--low-power` to cut heat.

## Other risks
- `disablesleep` is undocumented (it's not in `man pmset`) and unsupported. Apple's supported route is clamshell mode with power, an external display and an external keyboard.
- The biggest real risk is sleep left disabled by mistake, then the Mac goes into a bag and never sleeps. That's why the script restores sleep on every exit and `insomnia status` warns about a leftover setting.
- A MacBook Air has no fan, so closing it costs more performance, but its thermal limits still protect it.

## Thresholds the watchdog uses
- Thermal pressure (`powermetrics -s thermal`): Nominal, Moderate, Heavy, Trapping, Sleeping. Stops at Heavy or higher.
- Battery temperature (`ioreg -rn AppleSmartBattery`, in hundredths of a °C): under 35 is fine, 35–40 is worth watching, above 40–45 means act. 45 is the default stop.

## Sources
- Apple, closed-display mode: https://support.apple.com/en-bw/HT201834
- Apple, operating temperature: https://support.apple.com/en-us/102336
- Apple, battery temperature: https://www.apple.com/batteries/maximizing-performance/
- Apple, camera covers: https://support.apple.com/en-us/102177
- HotHardware, vent layout: https://hothardware.com/reviews/apple-macbook-pro-14-m1-pro-review?page=3
- Apple forum, warm display with lid closed: https://discussions.apple.com/thread/253793231
- Staingate: https://tidbits.com/2015/03/28/inconsistent-support-bedevils-macbook-pros-suffering-from-staingate/
