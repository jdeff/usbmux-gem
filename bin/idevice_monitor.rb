#!/usr/bin/env ruby

require 'usbmux'

mux = Usbmux::USBMux.new
puts "Waiting for devices..."
if !mux.devices
  mux.process(0.1)
end
loop do
  puts "Devices: "
  mux.devices.each do |device|
    puts device
  end
  mux.process()
end
