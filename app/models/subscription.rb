class Subscription < ActiveRecord::Base
  include SubscriptionProvider
  belongs_to :account
  validate :minutes_utlized_less_than_total_allowed_minutes
  validates :number_of_callers, numericality: { greater_than:  0}, :if => Proc.new{|subscription| subscription.per_agent? && subscription.status !=  Status::CALLERS_REMOVED}
  validate :downgrading_subscription
  validate :upgrading_to_per_minute
  default_scope order('created_at DESC')
  
  

  module Type
    TRIAL = "Trial"
    BASIC = "Basic"
    PRO = "Pro"
    BUSINESS = "Business"
    PER_MINUTE = "PerMinute"
    ENTERPRISE = "Enterprise"
    PAID_SUBSCRIPTIONS = [BASIC,PRO,BUSINESS, PER_MINUTE]
    PAID_SUBSCRIPTIONS_ORDER = {"Trial"=> 0, "Basic"=> 1, "Pro"=> 2, "Business"=> 3, "PerMinute"=>4}
  end

  module Status
    TRIAL = "Trial"
    UPGRADED = "Upgraded"
    CALLERS_ADDED = "Callers Added"
    CALLERS_REMOVED = "Callers Removed"
    SUSPENDED = "Suspended"
    CANCELED = "Canceled"    
    CURRENT = [TRIAL,UPGRADED,CALLERS_ADDED,CALLERS_REMOVED]
  end

  def activated?
    type == Type::TRIAL || status == Status::ACTIVE
  end

  def minutes_utlized_less_than_total_allowed_minutes    
    if minutes_utlized_changed? && available_minutes < 0
      errors.add(:base, 'You have consumed all your minutes for your subscription')
    end
  end

  def upgrading_to_per_minute
    if type_changed?             
      if self.changes["type"].last == Type::PER_MINUTE && self.changes["type"].first != Type::TRIAL  && available_minutes > 0 
      errors.add(:base, 'Please finish up your minutes before upgrading to per minute subscription.')
      end
    end
  end

  def downgrading_subscription
    if type_changed?             
      if Type::PAID_SUBSCRIPTIONS_ORDER[self.changes["type"].last] < Type::PAID_SUBSCRIPTIONS_ORDER[self.changes["type"].first]
      errors.add(:base, 'You cant downgrade your subscription till you utlize all your current minutes')
      end
    end
  end

  def self.subscription_type(type)
    type.constantize.new
  end

  def number_of_days_in_current_month
    Time.days_in_month(DateTime.now.month, DateTime.now.year)
  end
  
  def available_minutes
    days_of_subscription = (DateTime.now.to_date - subscription_start_date.to_date).to_i
    (days_of_subscription <= number_of_days_in_current_month) ? (total_allowed_minutes - minutes_utlized) : -1
  end

  def stripe_plan_id
    "ImpactDialing-" + type
  end

  def self.stripe_plan_id(type)
    "ImpactDialing-" + type
  end

  def update_customer_info(customer)            
    card_info = customer.cards.data.first
    subscription = customer.subscription
    self.update_attributes!(stripe_customer_id: customer.id, cc_last4: card_info.last4, exp_month: card_info.exp_month, 
    exp_year: card_info.exp_year, amount_paid: subscription.plan.amount/100, subscription_start_date: DateTime.strptime(subscription.current_period_start.to_s,'%s'),
    subscription_end_date: DateTime.strptime(subscription.current_period_end.to_s,'%s'))          
  end

  def update_subscription_info(subscription)        
    update_attributes(amount_paid: subscription.plan.amount/100, subscription_start_date: subscription.current_period_start,
    subscription_end_date: customer.subscription.current_period_end)      
  end

  def current_period_start
    current_subscription = account.current_subscription
    current_subscription.type == Type::TRIAL ? DateTime.now : current_subscription.subscription_start_date
  end


  def calculate_minutes_on_upgrade    
    days_remaining = number_of_days_in_current_month - (Subscription.todays_date - current_period_start.to_date).to_i            
    (minutes_per_caller/number_of_days_in_current_month) * days_remaining * number_of_callers
  end

  def calculate_minute_on_add_callers(number_of_callers_to_add)    
    days_remaining = number_of_days_in_current_month - (Subscription.todays_date - current_period_start.to_date).to_i
    (minutes_per_caller/number_of_days_in_current_month) * days_remaining * number_of_callers_to_add
  end

  def self.todays_date    
    DateTime.now.utc.to_date
  end


  def trial?
    type == Type::TRIAL
  end

  def per_agent?
    [Type::TRIAL, Type::BASIC, Type::PRO, Type::BUSINESS].include?(type)
  end

  def per_minute?
    type == Type::PER_MINUTE
  end

  def disable_call_recording
    account.update_attributes(record_calls: false)
  end

  def card_info
    unless cc_last4.nil?
      "xxxx xxxx xxxx " + cc_last4
    end
  end

  def cancelled?
    status == Status::CANCELED
  end

  def cancel
    cancel_subscription
    self.update_attributes(status: Status::CANCELED, stripe_customer_id: nil, cc_last4: nil, exp_year: nil, exp_month: nil)
  end


  def self.upgrade_subscription(account_id, token, email, plan_type, num_of_callers, amount)
    account = Account.find(account_id)    
    new_subscription = plan_type.constantize.new(type: plan_type, number_of_callers: num_of_callers, 
      status: Status::UPGRADED, account_id: account_id, amount_paid: amount)   
    new_subscription.subscribe    
    begin
      if trial_subscription?(account_id)                        
        customer = new_subscription.create_customer(token, email, plan_type, num_of_callers, amount)                        
        account.subscriptions.update_all(status: Status::SUSPENDED)        
        new_subscription.save        
        new_subscription.update_customer_info(customer)        
      else
        modified_subscription = new_subscription.update_subscription_plan({quantity: num_of_callers, plan: plan_type, prorate: true})
        account.current_subscriptions.update_all(status: Status::SUSPENDED)
        new_subscription.save
        new_subscription.update_subscription_info(modified_subscription)
      end
    rescue Stripe::InvalidRequestError => e     
        puts "in exception" 
        new_subscription.errors.add(:base, 'Please submit a valid number of callers')    
        return new_subscription
    rescue Stripe::APIError => e        
        new_subscription.errors.add(:base, 'Something went wrong with your upgrade. Kindly contact support')
        return new_subscription
    end 
      return new_subscription
     end

  def self.active_number_of_callers(account_id)
    account = Account.find(account_id)    
    account.current_subscriptions.map(&:number_of_callers).inject(0, &:+)
  end

  def self.modify_callers_to_existing_subscription(account_id, num_of_callers)        
    number_of_callers_to_add = num_of_callers - active_number_of_callers(account_id)    
    if number_of_callers_to_add > 0      
      add_callers(num_of_callers, account_id)
    elsif(number_of_callers_to_add == 0)      
      return identical_callers(account_id)
    else      
      remove_callers(num_of_callers, account_id)
    end  
  end

  def self.identical_callers(account_id)
    account = Account.find(account_id)    
    current_subscription = account.current_subscription
    current_subscription.errors.add(:base, 'The subscription details submitted are identical to what already exists')
    current_subscription
  end

  def self.add_callers(num_of_callers, account_id)
    number_of_callers_to_add = num_of_callers - active_number_of_callers(account_id)
    account = Account.find(account_id)    
    current_subscription = account.current_subscription

    new_subscription = current_subscription.type.capitalize.constantize.new(type: current_subscription.type, number_of_callers: number_of_callers_to_add, 
        status: Status::CALLERS_ADDED, account_id: account.id, minutes_utlized: 0,stripe_customer_id: current_subscription.stripe_customer_id)   
    new_subscription.total_allowed_minutes = new_subscription.calculate_minute_on_add_callers(number_of_callers_to_add)
    begin 
      modified_subscription = new_subscription.update_subscription_plan({quantity: num_of_callers, plan: current_subscription.stripe_plan_id, prorate: true})                  
      new_subscription.invoice_customer       
      new_subscription.save!      
      new_subscription.update_subscription_info(modified_subscription)      
    rescue
      new_subscription.errors.add(:base, 'Something went wrong with your upgrade. Kindly contact support')
    end
    return new_subscription
  end

  def self.remove_callers(num_of_callers, account_id)    
    account = Account.find(account_id)    
    number_of_callers_to_remove = num_of_callers - active_number_of_callers(account_id)
    begin      
        current_subscription = account.current_subscription
        modified_subscription = current_subscription.update_subscription_plan({quantity: num_of_callers, plan: current_subscription.stripe_plan_id, prorate: false})        
        new_subscription = current_subscription.type.capitalize.constantize.create(type: current_subscription.type, number_of_callers: number_of_callers_to_remove, 
        status: Status::CALLERS_REMOVED, account_id: account.id, minutes_utlized: 0,stripe_customer_id: current_subscription.stripe_customer_id)   
    rescue Stripe::InvalidRequestError => e
       current_subscription.errors.add(:base, 'Please submit a valid number of callers')    
       return current_subscription
    rescue Exception => e
      current_subscription.errors.add(:base, 'Something went wrong with your upgrade. Kindly contact support')
      return current_subscription
    end
    return new_subscription
  end

  def self.trial_subscription?(account_id)
    account = Account.find(account_id)
    subscription = account.subscriptions.detect{|subscription| subscription.type == Type::TRIAL}
    subscription != nil && account.subscriptions.count == 1
  end
  

end