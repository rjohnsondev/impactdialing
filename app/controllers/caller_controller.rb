require Rails.root.join("lib/twilio_lib")

class CallerController < ApplicationController
  layout "caller"
  before_filter :check_login, :except=>[:login, :feedback, :assign_campaign, :end_session, :pause, :start_calling, :gather_response]
  before_filter :redirect_to_ssl
  before_filter :connect_to_twilio, :only => [:preview_dial]

  def index
    unless @caller.account.activated?
      flash_now(:warning, "Your account is not funded. Please contact your account administrator.")
    end
    @campaigns = @caller.campaigns.manual.active.collect { |c| c if c.use_web_ui? }
  end


  def check_login
    if session[:caller].blank?
      redirect_to caller_login_path
      return
    end
    begin
      @caller = Caller.find(session[:caller])
    rescue
      logout
    end
  end

  def logout
    session[:caller]=nil
    redirect_to caller_root_path
  end

  def login
    @breadcrumb="Login"
    @title="Login to Impact Dialing"

    if !params[:email].blank?
      @caller = Caller.find_by_email_and_password(params[:email], params[:password])
      if @caller.blank?
        flash_now(:error, "Wrong email or password.")
      else
        session[:caller]=@caller.id
        redirect_to :action=>"index"
      end
    end
  end


  def assign_campaign
    @session = CallerSession.find(params[:session])
    caller = Caller.find(params[:id])
    @campaign = @session.caller.account.campaigns.find_by_campaign_id(params[:Digits])
    if @campaign
      @session.update_attributes(:campaign => @campaign)
      Moderator.caller_connected_to_campaign(caller, @campaign, @session)
      render :xml => @session.start
    else
      render :xml => @session.ask_for_campaign(params[:attempt].to_i)
    end
  end


  def stop_calling
    caller = Caller.find(params[:id])
    @session = caller.caller_sessions.find(params[:session_id])
    @session.end_running_call
    render :nothing => true
  end

  def pause
    caller = Caller.find(params[:id])
    caller_session = caller.caller_sessions.find(params[:session_id])
    if caller_session.disconnected?
      render :xml => Twilio::Verb.hangup
    else
      render :xml => caller_session.voter_in_progress ? caller_session.pause_for_results(params[:attempt]) : caller_session.start
    end
  end

  def gather_response
    caller = Caller.find(params[:id])
    caller_session = caller.caller_sessions.find(params[:session_id])
    question = Question.find_by_id(params[:question_id])
    voter = caller_session.voter_in_progress
    voter.answer(question, params[:Digits]) if voter && question

    xml = Twilio::Verb.hangup if caller_session.disconnected?
    xml ||= (voter.question_not_answered.try(:read, caller_session) if voter)
    xml ||= caller_session.start
    render :xml => xml
  end


  def end_session
    caller_session = CallerSession.find_by_sid(params[:CallSid])
    render :xml => caller_session.try(:end) || Twilio::Verb.hangup
  end

  def active_session
    caller = Caller.find(params[:id])
    campaign = caller.campaigns.find(params[:campaign_id])
    render :json => caller.caller_sessions.available.where("campaign_id = #{campaign.id}").last || {:caller_session => {:id => nil}}
  end

  def preview_voter
    caller_session = @caller.caller_sessions.find(params[:session_id])
    voter = caller_session.campaign.next_voter_in_dial_queue(params[:voter_id])
    caller_session.publish('caller_connected', voter ? voter.info : {}) if caller_session.campaign.predictive_type == Campaign::Type::PREVIEW || caller_session.campaign.predictive_type == Campaign::Type::PROGRESSIVE
    render :nothing => true
  end

  def skip_voter
    caller_session = @caller.caller_sessions.find(params[:session_id])
    voter = Voter.find(params[:voter_id])
    voter.skip
    next_voter = caller_session.campaign.next_voter_in_dial_queue(params[:voter_id])
    caller_session.publish('caller_connected', next_voter ? next_voter.info : {}) if caller_session.campaign.predictive_type == Campaign::Type::PREVIEW || caller_session.campaign.predictive_type == Campaign::Type::PROGRESSIVE
    render :nothing => true

  end

  def start_calling
    @caller = Caller.find(params[:caller_id])
    @campaign = Campaign.find(params[:campaign_id])
    @session = @caller.caller_sessions.create(on_call: false, available_for_call: false,
                                              session_key: generate_session_key, sid: params[:CallSid], campaign: @campaign)
    Moderator.caller_connected_to_campaign(@caller, @campaign, @session)
    render :xml => @session.start
  end


  def call_voter
    caller_session = @caller.caller_sessions.find(params[:session_id])
    voter = Voter.find(params[:voter_id])
    caller_session.preview_dial(voter)
    render :nothing => true
  end

  def ping
    #sleep 2.5
    send_rt(params[:key], 'ping', params[:num])
    render :text=>"pong"
  end

  def network_test
    @rand=rand
  end


  def drop_call
    @session = CallerSession.find_by_session_key(params[:key])
    return if @session.blank?
    attempt = CallAttempt.find(params[:attempt])
    t = TwilioLib.new(TWILIO_ACCOUNT, TWILIO_AUTH)
    a=t.call("POST", "Calls/#{attempt.sid}", {'CurrentUrl'=>"#{APP_URL}/callin/voterEndCall?attempt=#{attempt.id}"})
    render :text=> "var x='ok';"
  end

  def preview_choose
    @session = CallerSession.find_by_session_key(params[:key])
    @campaign = @session.campaign
    @voters = @campaign.voters("not called", true, 25)
    render :layout=>false
  end

  def reconnect_rt
    send_rt(params[:key], params[:k], params[:v])
    render :text=> "var x='ok';"
  end

  def preview_dial
    @session = CallerSession.find_by_session_key(params[:key])
    @campaign = @session.campaign
    @voter = Voter.find_by_campaign_id_and_id(@campaign.id, params[:voter_id])
    @session.call(@voter)
    send_rt(params[:key], 'waiting', 'preview_dialing')
    render :text=> "var x='ok';"
  end

  def connect_to_twilio
    Twilio.connect(TWILIO_ACCOUNT, TWILIO_AUTH)
  end

  def dpoll
    response.headers["Content-Type"] = 'text/javascript'

    @on_call = CallerSession.find_by_session_key(params[:key])
    if (@on_call==nil || @on_call.on_call==false)
      #hungup?  the view will reload the page in this case to reset the ui
    else
      @campaign = @on_call.campaign
    end
    respond_to do |format|
      format.js
    end
  end

  def feedback
    Postoffice.feedback(params[:issue]).deliver
    render :text=> "var x='ok';"
  end
end
