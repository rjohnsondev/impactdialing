class CallFlow::Call::Storage
  include CallFlow::DialQueue::Util

  attr_reader :account_sid, :call_sid, :namespace

private
  def validate!
    if account_sid.blank? or call_sid.blank?
      raise CallFlow::Call::InvalidParams, "CallFlow::Call::Data requires non-blank account_sid & call_sid."
    end
  end


public
  def initialize(account_sid, call_sid, namespace=nil)
    @account_sid = account_sid
    @call_sid    = call_sid
    @namespace   = namespace
    validate!
  end

  def self.key(account_sid, call_sid, namespace=nil)
    [
      'calls',
      account_sid,
      call_sid,
      namespace
    ].compact.join(':')
  end

  def key
    @key ||= self.class.key(account_sid, call_sid, namespace)
  end

  def [](property)
    redis.hget(key, property)
  end

  def []=(property, value)
    redis.hset(key, property, value)
  end

  def save(hash)
    p "key: #{key} saving: #{hash}"
    redis.mapped_hmset(key, hash)
  end

  def multi(&block)
    redis.multi(&block)
  end
end
