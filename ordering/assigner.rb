require 'rubygems'
require 'bud'
require 'backports'

require 'ordering/serializer'

module AssignerProto
  include BudModule

  state {
    interface input, :dump, [:payload]
    interface output, :pickup, [:ident] => [:payload]
  }
end

module Assigner
  include AssignerProto
  include SerializerProto

  declare 
  def logos 
    enqueue <= dump.map do |d|
      [d.join(","), d]
    end

    dequeue <= localtick

    pickup <= dequeue_resp.map{|r| [r.ident, r.payload] } 
  end
end


module AggAssign
  include AssignerProto

  state {
    scratch :holder, [:array]
    scratch :holder2, [:array]
  }
  
  declare 
  def grouping
    holder <= dump.group(nil, accum(dump.payload))
    #stdio <~ holder.map{|h| ["HOLD: #{h.inspect}"] }
    pickup <= holder.flat_map do |h|
      h.array.each_with_index.map{|a, i| [i, a] }
    end
  end
end
