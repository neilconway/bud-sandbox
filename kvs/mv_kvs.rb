require 'rubygems'
require 'bud'
require 'ordering/vector_clock'

module MVKVSProtocol
  state do
    interface input, :kvput, [:client, :key, :version] => [:reqid, :value]
    interface input, :kvget, [:reqid] => [:client, :key, :version]
    interface output, :kvget_response, [:reqid, :key, :version] => [:value]
  end
end

#build your own read/view policies on top of multiversions
#all versions of data item are returned
module BasicMVKVS
  include MVKVSProtocol

  state do
    table :kvstate, [:key, :version] => [:value]
  end
  
  bloom :put do
    kvstate <= kvput {|s| [s.key, s.version, s.value]}
  end

  bloom :get do
    temp :getj <= (kvget * kvstate).pairs(:key => :key)

    kvget_response <= getj do |g, t|
      [g.reqid, t.key, t.version, t.value]
    end
  end
end

#auto-increments vector clock on insert
#returns all matching vectors in DB on return
#vector merging, etc. needs to be handled by client/frontend module
module VC_MVKVS
  include MVKVSProtocol
  import BasicMVKVS => :mvkvs
  
  bloom :put do
    mvkvs.kvput <= kvput do |s|
      s.version.increment(s.client)
      [s.client, s.key, s.version.clone, s.reqid, s.value]
    end
  end

  bloom :pass_thru do
    mvkvs.kvget <= kvget
    kvget_response <= mvkvs.kvget_response
  end
end

#only causally consistent values can be read
#filter read for events that "happen after" supplied version/vector clock

#client needs to merge response version with its own local vector clock
#before making additional database requests
module Causal_MVKVS
  include MVKVSProtocol
  import VC_MVKVS => :vckvs

  bloom :pass_thru do
    vckvs.kvput <= kvput
    vckvs.kvget <= kvget
  end
  
  bloom :get do
    kvget_response <= (vckvs.kvget_response*kvget).pairs(:reqid => :reqid) do |r, c|
      if c.version.happens_before(r.version)
        r
      end
    end
  end
end

#implements monotonic reads
#expected access pattern: client maintains a write vector clock (passed in on puts)
#and a read vector clock (passed in on gets, updated when client chooses a value to read)
module MR_MVKVS
  include MVKVSProtocol
  import VC_MVKVS => :vckvs

  bloom :pass_thru do
    vckvs.kvput <= kvput
    vckvs.kvget <= kvget
  end

  bloom :get do
    kvget_response <= (vckvs.kvget_response*kvget).pairs(:reqid => :reqid) do |r, c|
      if c.version.happens_before_non_strict(r.version)
        r
      end
    end
  end
end

#implements read-your-writes consistency
module RYW_MVKVS
  include MVKVSProtocol
  import VC_MVKVS => :vckvs

  bloom :pass_thru do
    vckvs.kvput <= kvput
    vckvs.kvget <= kvget
  end
  
  bloom :get do
    kvget_response <= (vckvs.kvget_response*kvget).pairs(:reqid => :reqid) do |r, c|
      if c.version[c.client] <= r.version[c.client]
        r
      end
    end
  end
end

#implements monotonic writes consistency
module MW_MVKVS
  include MVKVSProtocol
  import BasicMVKVS => :mvkvs

  bloom :pass_thru do
    mvkvs.kvget <= kvget
  end

  bloom :put do
    mvkvs.kvput <= kvput do |s|
      s.version.increment(s.client)
      nv = VectorClock.new
      nv.set_client(s.client, s.version[s.client])
      [s.client, s.key, nv, s.reqid, s.value]
    end
  end

  bloom :get do
    kvget_response <= (mvkvs.kvget_response*kvget).pairs(:reqid => :reqid) do |r, c|
      mw = true

      for client in c.version.get_clients
        if c.version[client] > r.version[client] && r.version[client] != -1
          mw = false
          break
        end
      end

      if mw
        r
      end
    end
  end
end
