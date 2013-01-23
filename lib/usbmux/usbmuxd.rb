require 'rbconfig'
require 'cfpropertylist'
require 'socket'

module Usbmux
  class MuxError < RuntimeError; end
  class MuxVersionError < MuxError; end

  class SafeStreamSocket
    attr_accessor :sock

    def initialize(family, address)
      @sock = Socket.new(family, Socket::SOCK_STREAM)
      @sock.connect(address)
    end

    def send(message)
      total_sent = 0
      while total_sent < message.length
        sent = @sock.send(message[total_sent..-1], 0)
        if sent == 0
          raise MuxError.new('Socket connection broken')
        end
        total_sent += sent
      end
    end

    def receive(size)
      message = ''
      while message.length < size
        chunk = @sock.recv(size - message.length)
        if chunk.empty?
          raise MuxError.new('Socket connection broken')
        end
        message = message + chunk
      end
      message
    end

    def close
      @sock.close
    end
  end

  class MuxDevice
    attr_accessor :id, :usbprod, :serial, :location

    def initialize(id, usbprod, serial, location)
      @id = id
      @usbprod = usbprod
      @serial = serial
      @location = location
    end

    def to_s
      "<MuxDevice: ID #{@id} ProdID 0x#{@usbprod.to_s.rjust(4, '0')} Serial '#{@serial}' Location 0x#{@usbprod.to_s.rjust(4, '0')}>"
    end
  end

  class BinaryProtocol
    TYPE_RESULT = 1
    TYPE_CONNECT = 2
    TYPE_LISTEN = 3
    TYPE_DEVICE_ADD = 4
    TYPE_DEVICE_REMOVE = 5
    VERSION = 0

    attr_accessor :socket, :connected

    def initialize(socket)
      @socket = socket
      @connected = false
    end

    def send_packet(request, tag, payload = {})
      payload = _pack(request, payload)
      if connected?
        raise MuxError.new('Mux is connected, cannot issue control packets')
      end
      length = 16 + payload.length
      data = [length, self.class::VERSION, request, tag].pack('IIII') + payload
      @socket.send(data)
    end

    def get_packet
      if connected?
        raise MuxError.new('Mux is connected, cannot issue control packets')
      end
      dlen = @socket.receive(4)
      dlen = dlen.unpack('I').first
      body = @socket.receive(dlen - 4)
      version, response, tag = body[0..0xc].unpack('III')
      if version != self.class::VERSION
        raise MuxVersionError.new("Version mismatch: expected #{self.class::VERSION}, got #{version}")
      end
      payload = _unpack(response, body[0xc..-1])

      [response, tag, payload]
    end

    def connected?
      @connected
    end

    def _pack(request, payload)
      if request == TYPE_CONNECT
        [payload['DeviceID'], payload['PortNumber']].pack('IS_') + '\x00\x00'
      elsif request == TYPE_LISTEN
        ''
      else
        raise ArgumentError.new("Invalid outgoing request type #{request}")
      end
    end
    private :_pack

    def _unpack(response, payload)
      if response == TYPE_RESULT
        { 'Number' => payload[0].unpack('I') }
      elsif response == TYPE_DEVICE_ADD
        id, usbpid, serial, pad, location = payload.unpack('IS_b256S_I')
        serial = serial.split("\0")[0]
        {
          'DeviceID' => id,
          'Properties' =>
          {
            'LocationID' => location,
            'SerialNumber' => serial,
            'ProductID' => usbpid
          }
        }
      elsif response == TYPE_DEVICE_REMOVE
        { 'DeviceID' => payload.unpack('I').first }
      else
        raise MuxError.new("Invalid incoming request type #{request}")
      end
    end
    private :_unpack

  end

  class PlistProtocol < BinaryProtocol
    TYPE_RESULT = 'Result'
    TYPE_CONNECT = 'Connect'
    TYPE_LISTEN = 'Listen'
    TYPE_DEVICE_ADD = 'Attached'
    TYPE_DEVICE_REMOVE = 'Detached'
    TYPE_PLIST = 8
    VERSION = 1

    def send_packet(request, tag, payload = {})
      payload['ClientVersionString'] = 'usbmux.py by marcan'
      if request.is_a? Integer
        request = [TYPE_CONNECT, TYPE_LISTEN][request - 2]
      end
      payload['MessageType'] = request
      payload['ProgName'] = 'tcprelay'
      plist = CFPropertyList::List.new
      plist.value = CFPropertyList.guess(payload)
      xml = plist.to_str(CFPropertyList::List::FORMAT_XML, :formatted => true)
      
      super(TYPE_PLIST, tag, xml)
    end

    def get_packet
      response, tag, payload = super()
      if response != TYPE_PLIST
        raise MuxError.new("Received non-plist type #{response}")
      end

      [payload['MessageType'], tag, payload]
    end

    def _pack(request, payload)
      payload + "\n"
    end

    def _unpack(response, payload)
      payload = CFPropertyList::List.new(:data => payload).value.value
      response = payload['MessageType'].value
      if response == TYPE_RESULT
        { 'MessageType' => response, 'Number' => payload['Number'].value }
      elsif response == TYPE_DEVICE_ADD
        properties = payload['Properties'].value
        {
          'MessageType' => response,
          'DeviceID' => payload['DeviceID'].value,
          'Properties' =>
          {
            'LocationID' => properties['LocationID'].value,
            'SerialNumber' => properties['SerialNumber'].value,
            'ProductID' => properties['ProductID'].value
          }
        }
      elsif response == TYPE_DEVICE_REMOVE
        { 'MessageType' => response, 'DeviceID' => payload['DeviceID'].value }
      else
        raise MuxError.new("Invalid incoming response type #{response}")
      end
    end
  end

  class MuxConnection
    attr_accessor :socket_path, :socket, :protocol, :pkttag, :devices
    def initialize(socket_path, protocol_class)
      @socket_path = socket_path
      if RbConfig::CONFIG['host_os'] =~ /mswin|mingw/
        family = Socket::PF_INET
        address = Addrinfo.tcp('127.0.0.1', 27015)
      else
        family = Socket::PF_UNIX
        address = Addrinfo.unix('/var/run/usbmuxd')
      end
      @socket = SafeStreamSocket.new(family, address)
      @protocol = protocol_class.new(@socket)
      @pkttag = 1
      @devices = []
    end

    def listen
      ret = _exchange(@protocol.class::TYPE_LISTEN)
      if ret != 0
        raise MuxError.new("Listen failed: error #{ret}")
      end
    end

    def process(timeout = nil)
      if @protocol.connected?
        raise MuxError.new('Socket is connected, cannot process listener events')
      end
      rlo, wlo, xlo = IO.select([@socket.sock], [], [@socket.sock], timeout)
      if xlo.length > 0
        @socket.close
        raise MuxError.new("Exception in listener socket")
      elsif rlo.length > 0
        _process_packet
      end
    end

    def connect(device, port)
      payload = {
        'DeviceID' => device.id,
        'PortNumber' => (( port << 8) & 0xFF00) | (port >> 8)
      }
      ret = _exchange(@protocol.class::TYPE_CONNECT, payload)
      if ret != 0
        raise MuxError.new("Connect failed: error #{ret}")
      end
      @protocol.connected = true
      @socket.sock
    end

    def close
      @socket.close
    end

    def _get_reply
      response, tag, data = @protocol.get_packet
      if response == @protocol.class::TYPE_RESULT
        [tag, data]
      else
        raise MuxError.new("Invalid packet type received: #{response}")
      end
    end
    private :_get_reply

    def _process_packet
      response, tag, data = @protocol.get_packet
      if response == @protocol.class::TYPE_DEVICE_ADD
        device_id = data['DeviceID']
        product_id = data['Properties']['ProductID']
        udid = data['Properties']['SerialNumber']
        location_id = data['Properties']['LocationID']
        @devices << MuxDevice.new(device_id, product_id, udid, location_id)
      elsif response == @protocol.class::TYPE_DEVICE_REMOVE
        @devices.delete_if do |device|
          device.id == data['DeviceID']
        end
      elsif response == @protocol.class::TYPE_RESULT
        raise MuxError.new("Unexpected result: #{response}")
      else
        raise MuxError.new("Invalid packet type received: #{response}")
      end
    end
    private :_process_packet

    def _exchange(request, payload = {})
      my_tag = @pkttag
      @pkttag += 1
      @protocol.send_packet(request, my_tag, payload)
      receive_tag, data = _get_reply
      if receive_tag != my_tag
        raise MuxError.new("Reply tag mismatch: expected #{my_tag}, got #{receive_tag}")
      end
      data['Number']
    end
    private :_exchange
  end

  class USBMux
    attr_accessor :socket_path, :listener, :version, :protocol_class, :devices
    def initialize(socket_path = nil)
      if socket_path.nil?
        if RbConfig::CONFIG['host_os'] =~ /mswin|mingw/
          socket_path = '/var/run/usbmuxd'
        else
          socket_path = '/var/run/usbmuxd'
        end
      end
      @socket_path = socket_path
      begin
        @protocol_class = BinaryProtocol
        @version = 0
        @listener = MuxConnection.new(@socket_path, @protocol_class)
        @listener.listen()
      rescue MuxVersionError
        @protocol_class = PlistProtocol
        @version = 1
        @listener = MuxConnection.new(@socket_path, @protocol_class)
        @listener.listen()
      end
      @devices = @listener.devices
    end

    def process(timeout = nil)
      @listener.process(timeout)
    end

    def connect(device, port)
      connection = MuxConnection.new(@socket_path, @protocol_class)
      connection.connect(device, port)
    end
  end
end
