# RudeQ
require 'digest/sha1'
module RudeQ

  def self.included(mod)
    mod.extend(ClassMethods)
    mod.serialize(:data)
  end
  
  module ClassMethods
    # Cleanup old processed items
    #
    #   RudeQueue.cleanup!
    #   RudeQueue.cleanup!(1.week)
    def cleanup!(expiry=1.hour)
      self.delete_all(["processed = ? AND updated_at < ?", true, expiry.to_i.ago])
    end
  
    # Add any serialize-able *data* to the queue *queue_name* (strings and symbols are treated the same)
    #
    #   RudeQueue.set(:sausage_queue, Sausage.new(:sauce => "yummy"))
    #   RudeQueue.set("sausage_queue", Sausage.new(:other => true))
    #
    #     RudeQueue.get("sausage_queue")
    #     -> *yummy sausage*
    #     RudeQueue.get(:sausage_queue)
    #     -> *other_sausage*
    #     RudeQueue.get(:sausage_queue)
    #     -> nil
    def set(queue_name, data)
      queue_name = sanitize_queue_name(queue_name)
      self.create!(:queue_name => queue_name, :data => data)
      return nil # in line with Starling
    end

    # Grab the first item from the queue *queue_name* (strings and symbols are treated the same)
    # - it should always come out the same as it went in
    # - they should always come out in the same order they went in
    # - it will return a nil if there is no unprocessed entry in the queue
    #
    #  RudeQueue.get(21)
    #  -> {:a => "hash"}
    #  RudeQueue.get(:a_symbol)
    #  -> 255
    #  RudeQueue.get("a string")
    #  -> nil
    def get(queue_name)
      qname = sanitize_queue_name(queue_name)
      
      fetch_with_lock(qname) do |record|
        if record
          processed!(record)
          return record.data
        else
          return nil # Starling waits indefinitely for a corresponding queue item
        end
      end
    end

    # TODO: consider moving to a simple ActiveRecord :lock => true
    #   queued = self.find_by_queue_name_and_processed(qname, false, :lock => true)
    # in innodb this gives us a nice row lock
    #
    # if we use a transaction with the current tokenised lock
    # its equivalent to a table lock == :bad
    def fetch_with_lock(qname) # :nodoc:
      token = get_unique_token
      self.update_all(["token = ?", token], ["queue_name = ? AND processed = ? AND token IS NULL", qname, false], :limit => 1, :order => "id ASC")
      record = self.find_by_queue_name_and_token_and_processed(qname, token, false)
      
      return yield(record)
    end
    
    # class method to make it more easily stubbed
    def processed!(record) # :nodoc:
      # TODO: allow :set_flag and :destroy as :processed! options
      record.update_attribute(:processed, true)
    end
    protected :processed!
  
    def get_unique_token # :nodoc:

      digest = Digest::SHA1.new
      digest << Time.now.to_s
      digest << Process.pid.to_s
      digest << Socket.gethostname
      digest << self.token_count!.to_s # multiple requests from the same pid in the same second get different token
    
      return digest.hexdigest
    end
    
    protected
    
    def token_count! # :nodoc:
      @token_count ||= 0
      @token_count += 1
      return @token_count
    end
    
    def sanitize_queue_name(queue_name) # :nodoc:
      queue_name.to_s
    end
  end
end
