require Rails.root.join("lib/twilio_lib")

class AdminController < ApplicationController
  layout "basic"
  USER_NAME, PASSWORD = "impact", "Mb<3Ad4F@2tCallz"
  before_filter :authenticate
  require "nokogiri"

  def state
    if !params[:end].blank?
      cs = CallerSession.find(params[:end])
      cs.end_running_call
    end
    calls_to_end = CallAttempt.all(:conditions=>"tEndTime is not NULL and call_end is NULL")
    calls_to_end.each do |c|
      c.call_end = c.tEndTime
      c.save
    end
    if Time.now.hour > 0 && Time.now.hour < 6
      @calling_status = "<font color=red>Unavailable, off hours</font>".html_safe
    else
      @calling_status = "Available".html_safe
    end
    @all_calls = CallAttempt.find_all_by_call_end(nil).size
    @logged_in_campaigns = Campaign.all(:conditions=>"id in (select distinct campaign_id from caller_sessions where on_call=1)")
    @logged_in_callers = CallerSession.find_all_by_on_call(1)
    @ready_to_dial = CallAttempt.find_all_by_status("Call ready to dial", :conditions=>"call_end is null")
    @errors=""
    #t = TwilioLib.new(TWILIO_ACCOUNT, TWILIO_AUTH)
    #a=t.call("GET", "Calls?Status=queued", {})
    #doc  = Nokogiri::XML(a)
    #tcalls=doc.xpath("//Calls")
    #@queued=tcalls.first.attributes["total"].value if tcalls.length>0
  end

  def index

  end

  def report
    set_report_date_range
    sql="select distinct ca.campaign_id, name, c.account_id from caller_sessions ca
      join campaigns c on c.id=ca.campaign_id
      join accounts a on a.id=c.account_id where
      ca.created_at > '#{@from_date.strftime("%Y-%m-%d")}'
      and ca.created_at  < '#{(@to_date+1.day).strftime("%Y-%m-%d")}'
    "
    logger.info sql
    @campaigns = ActiveRecord::Base.connection.execute(sql)
    @output=[]
    @campaigns.each do |c|
      calls_sql="
      select count(*),  sum(ceil(tDuration/60)), sum(tPrice)
      from call_attempts ca
      where
      ca.created_at > '#{@from_date.strftime("%Y-%m-%d")}'
      and ca.created_at  < '#{(@to_date+1.day).strftime("%Y-%m-%d")}'
      and ca.campaign_id=#{c[0]}
      group by ca.campaign_id"
      session_sql="
      select count(*),  sum(ceil(tDuration/60)), sum(tPrice)
      from caller_sessions ca
      join campaigns c on c.id=ca.campaign_id
      join accounts a on a.id=c.account_id
      where
      ca.created_at > '#{@from_date.strftime("%Y-%m-%d")}'
      and ca.created_at  < '#{(@to_date+1.day).strftime("%Y-%m-%d")}'
      and ca.campaign_id=#{c[0]}
      group by ca.campaign_id"
      @calls = ActiveRecord::Base.connection.execute(calls_sql)
      @sessions = ActiveRecord::Base.connection.execute(session_sql)
      result={}
      result["calls"]=@calls
      result["sessions"]=@sessions
      result["campaign"]=c
      @output<< result
    end

    render :layout=>"client"
  end

  def set_report_date_range
    begin
      if params[:from_date]
        @from_date=Date.parse(params[:from_date])
        @to_date = Date.parse(params[:to_date])
      else
        @from_date = 1.month.ago
        @to_date = DateTime.now
      end
    rescue
      #just use the defaults below
    end

    @from_date = 1.month.ago if @from_date==nil
    @to_date = DateTime.now if @to_date==nil

  end

  def users
    @accounts = Account.all
  end

  def toggle_activated
    account = Account.find(params[:id])
    account.update_attribute(:activated, !account.activated)
    redirect_to :back
  end

  def toggle_card_verified
    account = Account.find(params[:id])
    account.update_attribute(:card_verified, !account.card_verified)
    redirect_to :back
  end

  def login
    session[:user]=params[:id]
    redirect_to :controller=>"client", :action=>"index"
  end

  def cms
    @version = session[:cms_version]
    @keys = Seo.all.map { |i| i.crmkey }.uniq
    @keys.delete_if { |x| x == nil }
    @keys.sort!
  end

  def add_cms
    if request.post?
      s = Seo.new
      s.crmkey=params[:key]
      s.content = params[:content]
      s.active=1
      s.save
      s.version=session[:cms_version]
      s.version=nil if session[:cms_version].blank?
      flash_message(:notice, "CMS updated successfully")
      redirect_to :action=>"cms"
    end
  end

  def edit_cms
    @seo = Seo.new
    @seoold = Seo.find(params[:id])
    @seo.crmkey = @seoold.crmkey
    @seo.content = @seoold.content
    @version = session[:cms_version]
    if request.post?
      @seo.attributes = params[:seo]
      @seoold.active=0
      @seoold.save
      @seo.active=1
      @seo.version=session[:cms_version]
      @seo.version=nil if session[:cms_version].blank?
      @seo.save
      flash_message(:notice, "CMS updated successfully")
      redirect_to :action=>"cms"
      return
    end
  end

  def pick_version
    if request.post?
      if params[:v]
        session[:cms_version]=params[:v]
        session[:cms_version]=nil if params[:v].blank? || params[:v]=="Live"
        flash_message(:notice, "CMS version changed")
        redirect_to :action=>"cms"
      end
      if !params[:nv].blank?
        test = Seo.find_by_version(params[:nv])
        if !test.blank?
          render :text=>"error - version already created!"
          return
        else
          # x = Seo.new
          # x.crmkey="optimizer_control_script"
          # x.active=1
          # x.version=params[:nv].strip
          # x.save
          # session[:cms_version]=x.version
          session[:cms_version]=params[:nv].strip
          flash_message(:notice, "CMS version added successfully")
          redirect_to :action=>"cms"
        end
      end
    end
    @versions = Seo.all.map { |i| i.version }.uniq
  end

  def robo_log_parse
    counter = 1
    out=[]
    f = File.new(Rails.root.join('result_combined.txt'))
    while (line = f.gets)
      hash = eval(line.gsub("Parameters:", "").strip)
      out << hash["attempt"]
      counter = counter + 1
    end
    render :text=>out.join(",")
  end

  def copy_cms
    @version = session[:cms_version]
    @source = Seo.find(params[:id])

    if request.post?
      s = Seo.new
      s.crmkey=params[:key]
      s.content = params[:content]
      s.active=1
      s.version=session[:cms_version]
      s.version=nil if session[:cms_version].blank?
      s.save
      flash_message(:notice, "CMS updated successfully")
      redirect_to :action=>"cms"
    end
  end

  def charge
    @account = Account.find(params[:id])
    @billing_account = @account.billing_account
    @emails = @account.users.map(&:email).join(', ')
    if @billing_account.nil?
      render :text => "User has not entered credit card info"
      return
    end
    if request.post?
      @success = charge_account(@billing_account, params[:tocharge].to_f)
    end
  end

  def charge_account(billing_account, amount)
    creditcard = ActiveMerchant::Billing::CreditCard.new(
        :number => billing_account.decrypt_cc,
        :month => billing_account.expires_month,
        :year => billing_account.expires_year,
        :type => billing_account.cardtype,
        :first_name => billing_account.first_name,
        :last_name => billing_account.last_name
    )

    user = billing_account.account.users.first
    billing_address = {
        :name => "#{user.fname} #{user.lname}",
        :address1 => billing_account.address1,
        :zip => billing_account.zip,
        :city => billing_account.city,
        :state => billing_account.state,
        :country => 'US'
    }
    options = {:address => {}, :address1 => billing_address, :billing_address => billing_address, :ip=>"127.0.0.1", :order_id=>""}
    @response = BILLING_GW.authorize(amount.to_f*100, creditcard, options)

    if @response.message == 'APPROVED'
      BILLING_GW.capture(@amount, @response.authorization)
      true
    else
      false
    end

  end

  def log
    if params[:id]
      @reqs=Dump.find_all_by_guid(params[:id], :order=>"first_line")
      @session=0
      @reqs.each do |r|
        begin
          p=YAML.load(r.params)
          @session=p[:session] if p[:session]!=nil
        rescue
        end
      end
      @attempts = CallAttempt.find_all_by_caller_session_id(@session, :order=>"id")
    end
  end

  private
  def authenticate
    authenticate_or_request_with_http_basic(self.class.controller_path) do |user_name, password|
      user_name == USER_NAME && password == PASSWORD
    end
  end
end
