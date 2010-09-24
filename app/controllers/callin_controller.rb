class CallinController < ApplicationController
  skip_before_filter :verify_authenticity_token
  before_filter :set_vars, :preload_models

  def set_vars
    @say=false
    @play=false
    @gather=false
    @redirect=false
    @hangup=false
    @pause=0
    @repeatRedirect=false
    @finishOnKey="#"
    @gatherPost=""
  end


  def index
    
    if params[:CallStatus]=="completed"
      if cookies[:session]==nil || cookies[:session]=="0"
        render :template => 'callin/index.xml.builder', :layout => false
        return
      end
      #remove this caller
      @session = CallerSession.find(cookies[:session])
      @session.endtime=Time.now
      @session.available_for_call=false
      @session.on_call=false
      @session.save
      # avail_campaign_hash = cache_get("avail_campaign_hash") {{}}
      # if avail_campaign_hash.has_key?(@session.campaign_id)
      #   thisSession = avail_campaign_hash[@session.campaign_id]["callers"].index(@session)
      #   if thisSession!=nil
      #     avail_campaign_hash[@session.campaign_id]["callers"].delete_at(thisSession)
      #     cache_set("avail_campaign_hash") {avail_campaign_hash}
      #   end
      # end
      render :template => 'callin/index.xml.builder', :layout => false
      return
    end


    
    # initial call-in
    att = params[:att] || 0
    if params[:att]=="3"
#      @say="If you don't have a PIN, please ask your campaign manager for one and call back. Good-bye."
      @play="#{APP_URL}/wav/no_pin.wav"
      @hangup=true
      render :template => 'callin/index.xml.builder', :layout => false
      return
    end

    @repeatRedirect="#{APP_URL}/callin?att=#{att.to_i+1}"
    @gatherPost = @repeatRedirect
    if params[:Digits].blank?
      # initial call-in
#      @say="Welcome to Impact Dialing.  Please enter your pin."
      @play="#{APP_URL}/wav/welcome.wav"
      cookies[:session]=nil
    else
      # response with PIN
      c = Caller.find_by_pin_and_active(params[:Digits], true)
      if c.blank?
#        @say="We could not find that pin, try again."
        @redirect="#{APP_URL}/callin/enter_group?session=0"
      else
        multi="ok"
        if !c.multi_user?
          logged_in = CallerSession.find_all_by_caller_id_and_on_call(c.id, true)
          if logged_in.length > 0
            multi="bad"
          end
          #check if user logged in already
          # avail_campaign_hash = cache_get("avail_campaign_hash") {{}}
          # avail_campaign_hash.keys.each do |k|
          #   callerSessions = avail_campaign_hash[k]["callers"]
          #   callerSessions.each do |sess|
          #     if sess.caller_id==c.id
          #       multi="bad"
          #     end
          #   end
          # end
        end

        
        if multi=="ok"
          # redirect to group ID
          s = CallerSession.new
          s.caller_number = params[:Caller]
          s.caller_id=c.id
          s.sid = params[:CallSid]
          s.save
          @redirect="#{APP_URL}/callin/enter_group?session=#{s.id}"
        else
#          @say="That PIN is already in use. Please enter another PIN."
          @play="#{APP_URL}/wav/pin_in_use.wav"
        end
      end
    end

    @gather=true
    @numDigits=5

    render :template => 'callin/index.xml.builder', :layout => false

    #"CallStatus"=>"in-progress",
    #"CallStatus"=>"completed"
  end
  
  def enter_group
    # params - session

    att = params[:att] || 0
    if params[:att]=="3"
#      @say="If you don't have a campaign ID, please ask your campaign manager for one and call back. Good-bye."
      @play="#{APP_URL}/wav/no_pin.wav"
      @hangup=true
      render :template => 'callin/index.xml.builder', :layout => false
      return
    end

    @repeatRedirect="#{APP_URL}/callin/enter_group?session=#{params[:session]}&att=#{att.to_i+1}"
    @gatherPost = @repeatRedirect
    if params[:session]!="0"
      @session = CallerSession.find(params[:session]) 
      cookies[:session] = @session.id
      @caller = @session.caller
    end

    if params[:Digits].blank?
      # initial call-in
#      @say="Now enter your campaign ID"
      @play="#{APP_URL}/wav/enter_campaign_id.wav"  
    else
      # response with PIN
      c = Campaign.find_by_group_id_and_active_and_user_id(params[:Digits], true, @caller.user_id) if params[:session]!="0"
      if params[:session]=="0" || c.blank?
#        @say="We could not find that campain, try again."
        @play="#{APP_URL}/wav/invalid_credentials.wav"
        @gather=false
        @repeatRedirect="#{APP_URL}/callin"
      elsif c.callers.index(@caller)==nil
        @say="You do not have access to this campaign.  Goodbye."
        @hangup=true
      else
        # redirect to group ID
        @session.campaign_id=c.id
        @session.save
        @redirect="#{APP_URL}/callin/get_ready?session=#{@session.id}&campaign=#{c.id}"
      end
    end

    if @repeatRedirect!="#{APP_URL}/callin"
      @gather=true
      @numDigits=5
    end

    render :template => 'callin/index.xml.builder', :layout => false
  end

  
  def get_ready
    # params - session, campaign
    @finishOnKey=""
    @repeatRedirect="#{APP_URL}/callin/enter_group?session=#{params[:session]}&campaign=#{params[:campaign]}"
    @session = CallerSession.find(params[:session]) 
    @caller = @session.caller
    @campaign = Campaign.find(params[:campaign])

    if params[:Digits].blank?
#      @say="Press star to begin taking calls, or press pound for instructions."
      @play="#{APP_URL}/wav/star_or_pound.wav"    
    else
      if params[:Digits]=="*"
        #send to conference room
        @session.starttime=Time.now
        @session.available_for_call=true
        @session.on_call=true
        @session.save
        #avail_campaign_hash = cache_get("avail_campaign_hash") {{}}
        # if !avail_campaign_hash.has_key?(@campaign.id)
        #   avail_campaign_hash[@campaign.id] = {"callers"=>[@session], "calls"=>[]}
        # else
        #   if !avail_campaign_hash[@campaign.id]["callers"].index(@session)
        #     avail_campaign_hash[@campaign.id]["callers"] << @session
        #   end
        # end
        # cache_set("avail_campaign_hash") {avail_campaign_hash}
        render :template => 'callin/start_conference.xml.builder', :layout => false
        return
      elsif params[:Digits]=="#"
        #@say= "Impact Dialing eliminates unanswered phone calls, allowing you to spend your time talking to people instead of waiting for someone to pick up. When you're ready to start taking calls, press the star key. You'll hear a brief period of silence while Impact Dialing finds a someone who answers the phone. When you've been connected to someone, you'll hear this sound: bee-doop. You usually won't hear the person say hello, so start talking immediately. At the end of the conversation, do not hang up the phone. Instead, press star to end the call, and then enter the call result on your phone's keypad. Then press star to submit the result and keep taking calls, or press pound to submit the result and hang up. You will now be connected to the system. In a moment Impact Dialing will deliver you a call. Begin taking calls.  After a call: say Please enter your call result. Then press star to submit and keep taking calls, or press pound to submit and hang up."
        @play="#{APP_URL}/wav/instructions.wav"    
        render :template => 'callin/start_conference.xml.builder', :layout => false
        return
      else
#        @say="Press star to begin taking calls.  Press pound for instructions."
        @play="#{APP_URL}/wav/star_or_pound.wav"    
      end
    end

    @gather=true
    @numDigits=1

    render :template => 'callin/index.xml.builder', :layout => false
  end
    
  def voterEndCall
    attempt = CallAttempt.find(params[:attempt])
    @hangup=true
    render :template => 'callin/index.xml.builder', :layout => false
  end
  
  def leaveConf
    # reached after call ends
    @repeatRedirect="#{APP_URL}/callin/leaveConf?session=#{params[:session]}&campaign=#{params[:campaign]}"
    @session = CallerSession.find(params[:session]) 
    @caller = @session.caller
    @campaign = @session.campaign

    if params[:Digits].blank?
      #hangup on voter
      #not needed - endConferenceOnExit
      # attempt = CallAttempt.find_by_voter_id(@session.voter_in_progress, :order=>"id desc", :limit=>1)
      #       if attempt!=nil
      #         t = Twilio.new(TWILIO_ACCOUNT, TWILIO_AUTH)
      #         a=t.call("POST", "Calls/#{attempt.sid}", {'CurrentUrl'=>"#{APP_URL}/callin/voterEndCall?attempt=#{attempt.id}"})
      #       end
            # initial call-in
#      @play="#{APP_URL}/exitBeep.wav"
      @play="#{APP_URL}/wav/beep_enter_call_result.wav"    
#      @say="Please enter your call result. Then press star to submit and keep taking calls."
      if @session.voter_in_progress!=nil
       voter = Voter.find(@session.voter_in_progress)
       voter.status='Call finished'
       voter.result="No Disposition"
       #attempt = CallAttempt.find_by_voter_id(@session.voter_in_progress, :order=>"id desc", :limit=>1)
       attempt = CallAttempt.find(@session.attempt_in_progress)
       attempt.result="No Disposition"
       attempt.save
       voter.save
      end
     else
      # digits entered, response given
      if params[:Digits]=="*"
        @say="Goodbye"
        @hangup=true
      else
        clean_digit = params[:Digits].gsub("#","").gsub("*","").slice(0..1)
#        @say="Thank you."
        if @session.voter_in_progress!=nil
          voter = Voter.find(@session.voter_in_progress)
          voter.status='Call finished'
          voter.result_digit=clean_digit
          voter.result_date=Time.now
          voter.caller_id=@caller.id
          attempt = CallAttempt.find(@session.attempt_in_progress)
          #attempt = CallAttempt.find_by_voter_id(@session.voter_in_progress, :order=>"id desc", :limit=>1)
          attempt.result_digit=clean_digit

          voter.attempt_id=attempt.id if attempt!=nil
          if @campaign.script!=nil
            voter.result=eval("@campaign.script.keypad_" + clean_digit)
            attempt.result=eval("@campaign.script.keypad_" + clean_digit)
            begin
              if @campaign.script.incompletes!=nil
                if eval(@campaign.script.incompletes).index(clean_digit)
                  voter.call_back=true
                end
              end
            rescue
            end
          end
          attempt.save
          voter.save
        end
        @session = CallerSession.find(params[:session]) 
        if @session.endtime==nil
          @session.available_for_call=true
          @session.voter_in_progress=nil
          @session.attempt_in_progress=nil
          @session.save
        end
        
        #send to conference room
        render :template => 'callin/start_conference.xml.builder', :layout => false
        return
      end
    end

    @gather=true
    @numDigits=3
    @finishOnKey="*"

    render :template => 'callin/index.xml.builder', :layout => false
  end
  
  # def voterleaveConf
  #    @hangup=true
  #    render :template => 'callin/index.xml.builder', :layout => false
  # end
  
  def voterFindSession
    # params session, voter, attempt
    # first callback for voters

    @campaign  = Campaign.find(params[:campaign])
    @voter = Voter.find(params[:voter])
#    attempt = CallAttempt.find_by_voter_id(params[:voter], :order=>"id desc", :limit=>1)
    attempt = CallAttempt.find(params[:attempt])
    if attempt.answertime==nil
      attempt.answertime=Time.now
      attempt.save
    end

    if params[:CallStatus]=="completed" || params[:CallStatus]=="no-answer" || params[:CallStatus]=="busy" || params[:CallStatus]=="failed" || params[:CallStatus]=="canceled"
      #clean up voter hangup
      
      # if params[:CallStatus]!="completed" 
      #   t = Twilio.new(TWILIO_ACCOUNT,TWILIO_AUTH)
      #   a=t.call("POST", "Calls/#{attempt.sid}", {'CurrentUrl'=>"#{APP_URL}/callin/voterEndCall?attempt=#{attempt.id}"})
      #   attempt.call_end=Time.now
      #   attempt.save
      # end
      
      
      if params[:DialStatus]=="hangup-machine"
        @voter.status="Hangup or answering machine"
        attempt.status="Hangup or answering machine"
        @voter.call_back=true
      elsif params[:DialStatus]=="no-answer"
        @voter.status="No answer"
        attempt.status="No answer"
        @voter.call_back=true
      elsif params[:CallStatus]=="busy"
        @voter.status="No answer busy signal"
        attempt.status="No answer busy signal"
        @voter.call_back=true
        t = Twilio.new(TWILIO_ACCOUNT, TWILIO_AUTH)
        a=t.call("POST", "Calls/#{attempt.sid}", {'CurrentUrl'=>"#{APP_URL}/callin/voterEndCall?attempt=#{attempt.id}"})
      elsif params[:CallStatus]=="canceled"
        @voter.status="Call cancelled"
        attempt.status="Call cancelled"
        @voter.call_back=false
      elsif params[:CallStatus]=="failed"
        @voter.status="Call failed"
        attempt.status="Call failed"
        @voter.call_back=false
      else
        if attempt.caller_id==nil
          #abandon
#          @voter.status="Call completed with success."
          attempt.status="Call abandoned"
        else
          @voter.status="Call completed with success."
          attempt.status="Call completed with success."
        end
      end
      attempt.call_end=Time.now
      attempt.save
      @voter.save
      if @voter.caller_session_id!=nil
        @session = CallerSession.find(@voter.caller_session_id)
        if @session.endtime==nil
#          @session.available_for_call=true
          @session.save
        end
      end
      # avail_campaign_hash = cache_get("avail_campaign_hash") {{}}
      # if avail_campaign_hash.has_key?(attempt.campaign_id)
      #   all_attempts = avail_campaign_hash[attempt.campaign_id]["calls"]
      #   n=0
      #   all_attempts.each do |mem_attempt|
      #     if mem_attempt.id == attempt.id
      #       avail_campaign_hash[attempt.campaign_id]["calls"].delete_at(n)
      #       cache_set("avail_campaign_hash") {avail_campaign_hash}
      #     end
      #     n+=1
      #   end
        # thisAttempt = avail_campaign_hash[attempt.campaign_id]["calls"].index(attempt)
        # if thisAttempt!=nil
        #   avail_campaign_hash[attempt.campaign_id]["calls"].delete_at(thisAttempt)
        #   cache_set("avail_campaign_hash") {avail_campaign_hash}
        # end
      #end
      render :template => 'callin/index.xml.builder', :layout => false
      return
    end

    
    @availableCaller = CallerSession.find_by_campaign_id_and_available_for_call(@campaign.id, true)
    if @availableCaller.blank?
      @pause=2
      @redirect="#{APP_URL}/callin/voterFindSession?campaign=#{@campaign.id}&voter=#{@voter.id}"
    else
      @availableCaller.voter_in_progress = @voter.id
      @availableCaller.attempt_in_progress = attempt.id
      @availableCaller.save
      attempt.caller_session_id=@availableCaller.id
      attempt.caller_id=@availableCaller.caller.id
      attempt.call_start=Time.now
      attempt.save
      #old@redirect="#{APP_URL}/callin/voterStart?session=#{@availableCaller.id}&voter=#{@voter.id}&attempt=#{attempt.id}"
      # new
      @attempt=attempt
      @session = @availableCaller
      @session.available_for_call=false
      # end caller hold time
      @attempt.caller_hold_time = (Time.now - @session.hold_time_start).to_i if @session.hold_time_start!=nil
      @attempt.save
      @session.hold_time_start=nil
      @session.save
      @caller = @session.caller
      @voter.status = "Connected to caller #{@caller.pin} #{@caller.email}"
      @voter.caller_session_id=@session.id
      @voter.save
      render :template => 'callin/voter_start_conference.xml.builder', :layout => false
      return
    end

    render :template => 'callin/index.xml.builder', :layout => false
    return
      
  end

  # def voterStart
  #   # params session, voter, attempt
  #   @session = CallerSession.find(params[:session]) 
  #   @session.available_for_call=false
  #   @session.save
  #   @caller = @session.caller
  #   @voter = Voter.find(params[:voter])
  #   @voter.status = "Connected to caller #{@caller.pin} #{@caller.email}"
  #   @voter.caller_session_id=@session.id
  #   @voter.save
  #   render :template => 'callin/voter_start_conference.xml.builder', :layout => false
  #   return
  # end
  
  def test
    # response.headers["Pragma"] = "no-cache"
    # response.headers["Cache-Control"] = "no-cache"
    # @play="#{APP_URL}/canta.mp3"
    # @hangup="true"
    # render :template => 'callin/index.xml.builder', :layout => false
    # return
    num = rand(100)
    if num < 10
      render :template => 'callin/reject.xml.builder', :layout => false
    elsif num < 60
      render :template => 'callin/pause.xml.builder', :layout => false
    else
      @play="#{APP_URL}/canta.mp3"
      @play2="#{APP_URL}/canta.mp3"
      @hangup="true"
      render :template => 'callin/index.xml.builder', :layout => false
    end
  end

end
