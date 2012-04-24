require "spec_helper"

describe Caller do
  include Rails.application.routes.url_helpers

  let(:user) { Factory(:user) }
  it "restoring makes it active" do
    caller_object = Factory(:caller, :active => false)
    caller_object.restore
    caller_object.active?.should == true
  end

  it "sorts by the updated date" do
    Caller.record_timestamps = false
    older_caller = Factory(:caller).tap { |c| c.update_attribute(:updated_at, 2.days.ago) }
    newer_caller = Factory(:caller).tap { |c| c.update_attribute(:updated_at, 1.day.ago) }
    Caller.record_timestamps = true
    Caller.by_updated.all.should == [newer_caller, older_caller]
  end

  it "lists active callers" do
    active_caller = Factory(:caller, :active => true)
    inactive_caller = Factory(:caller, :active => false)
    Caller.active.should == [active_caller]
  end

  it "calls in to the campaign" do
    Twilio::REST::Client
    sid = "gogaruko"
    caller = Factory(:caller, :account => user.account)
    campaign = Factory(:campaign, :account => user.account)
    TwilioClient.stub_chain(:instance, :account, :calls, :create).and_return(mock(:response, :sid => sid))
    caller.callin(campaign)
  end

  it "asks for pin" do
    Caller.ask_for_pin.should ==
        Twilio::Verb.new do |v|
          3.times do
            v.gather(:numDigits => 5, :timeout => 10, :action => identify_caller_url(:host => Settings.host, :port => Settings.port, :attempt => 1), :method => "POST") do
              v.say "Please enter your pin."
            end
          end
        end.response
  end

  it "asks for pin again" do
    Caller.ask_for_pin(1).should == Twilio::Verb.new do |v|
      3.times do
        v.gather(:numDigits => 5, :timeout => 10, :action => identify_caller_url(:host => Settings.host, :port => Settings.port, :attempt => 2), :method => "POST") do
          v.say "Incorrect Pin. Please enter your pin."
        end
      end
    end.response
  end

  it "redirects to hold call" do
    Caller.hold.should == Twilio::Verb.new { |v| v.play("#{APP_URL}/wav/hold.mp3"); v.redirect(hold_call_path(:host => Settings.host, :port => Settings.port), :method => "GET")}.response
  end

  it "is known as the name unless blank" do
    name, mail = 'name', "mail@mail.com"
    web_ui_caller = Factory(:caller, :name => '', :email => mail)
    phones_only_caller = Factory(:caller, :name => name, :email => '')
    web_ui_caller.known_as.should == mail
    phones_only_caller.known_as.should == name
  end


  it "returns name for phone-only-caller, email for web-caller " do
    phones_only_caller = Factory(:caller, :is_phones_only => true, :name => "name", :email => "email1@gmail.com")
    web_caller = Factory(:caller, :is_phones_only => false, :name => "name", :email => "email2@gmail.com")
    phones_only_caller.identity_name.should == "name"
    web_caller.identity_name.should == "email2@gmail.com"
  end


  describe "reports" do
    let(:caller) { Factory(:caller, :account => user.account) }
    let!(:from_time) { 5.minutes.ago }
    let!(:time_now) { Time.now }

    before(:each) do
      Factory(:caller_session, tCaller: "+18583829141", starttime: Time.now, endtime: Time.now + (30.minutes + 2.seconds), :tDuration => 10.minutes + 2.seconds, :caller => caller).tap { |ca| ca.update_attribute(:created_at, from_time) }
      Factory(:caller_session, starttime: Time.now, endtime: Time.now + (101.minutes + 57.seconds), :tDuration => 101.minutes + 57.seconds, :caller => caller).tap { |ca| ca.update_attribute(:created_at, from_time) }
      Factory(:call_attempt, connecttime: Time.now, call_end: Time.now + (10.minutes + 10.seconds), wrapup_time: Time.now + (10.minutes + 40.seconds), :tDuration => 10.minutes + 2.seconds, :status => CallAttempt::Status::SUCCESS, :caller => caller).tap { |ca| ca.update_attribute(:created_at, from_time) }
      Factory(:call_attempt, connecttime: Time.now, call_end: Time.now + (1.minutes), :tDuration => 1.minutes, :status => CallAttempt::Status::VOICEMAIL, :caller => caller).tap { |ca| ca.update_attribute(:created_at, from_time) }
      Factory(:call_attempt, connecttime: Time.now, call_end: Time.now + (101.minutes + 57.seconds), wrapup_time: Time.now + (102.minutes + 57.seconds), :tDuration => 101.minutes + 57.seconds, :status => CallAttempt::Status::SUCCESS, :caller => caller).tap { |ca| ca.update_attribute(:created_at, from_time) }
      Factory(:call_attempt, connecttime: Time.now, call_end: Time.now + (1.minutes), :tDuration => 1.minutes, :status => CallAttempt::Status::ABANDONED, :caller => caller).tap { |ca| ca.update_attribute(:created_at, from_time) }
    end

    describe "utilization" do
      it "lists time logged in" do
        CallerSession.time_logged_in(caller, nil, from_time, time_now).should == "7919"
      end

      it "lists on call time" do
        CallAttempt.time_on_call(caller, nil, from_time, time_now).should == "6727"
      end

      it "lists on wrapup time" do
        CallAttempt.time_in_wrapup(caller, nil, from_time, time_now).should == "90"
      end


    end

    describe "billing" do
      it "lists caller time" do
        CallerSession.caller_time(caller, nil, from_time, time_now).should == 31
      end

      it "lists lead time" do
        CallAttempt.lead_time(caller, nil, from_time, time_now).should == 113
      end
    end

    describe "campaign" do

      let(:voter) { Factory(:voter) }
      let(:question) { Factory(:question, :text => "what?", :script => Factory(:script)) }

      it "gets stats for answered calls" do
        response_1 = Factory(:possible_response, :value => "foo")
        response_2 = Factory(:possible_response, :value => "bar")
        campaign = Factory(:campaign)
        3.times { Factory(:answer, :caller => caller, :voter => voter, :question => question, :possible_response => response_1, :campaign => campaign) }
        2.times { Factory(:answer, :caller => caller, :voter => voter, :question => question, :possible_response => response_2, :campaign => campaign) }
        Factory(:answer, :caller => caller, :voter => voter, :question => question, :possible_response => response_1, :campaign => Factory(:campaign))
        stats = caller.answered_call_stats(from_time, time_now+1.day, campaign)
        stats.should == {"what?" => {
          :total => {:count => 5, :percentage => 100},
          "foo" => {:count => 3, :percentage => 60},
          "bar" => {:count => 2, :percentage => 40},
        }}
      end
    end
  end
end
