require 'resque-loner'
require 'librato_resque'

##
# Run periodically to persist call data from redis to the relational database.
# Call data is pushed to a redis list based on the call outcome. This job
# processes each list in turn and imports call data to the appropriate places.
#
# ### Metrics
#
# - completed
# - failed
# - timing
# - sql timing
#
# ### Monitoring
#
# Alert conditions:
#
# - 1 failure (WARNING: Exception rescued in a few spots)
# - stops reporting for 5 minutes
#
# todo: stop rescuing exception
class PersistCalls
  LIMIT = 1000
  include Resque::Plugins::UniqueJob
  extend LibratoResque

  @queue = :persist_jobs

  def self.perform
    abandoned_calls(LIMIT)
    unanswered_calls(LIMIT*3)
    machine_calls(LIMIT)
    disconnected_calls(LIMIT)
    wrapped_up_calls(LIMIT)
  end

  def self.pending_key(list_name)
    "#{list_name}.pending"
  end

  def self.rpoplpush(connection, list_name)
    connection.rpoplpush list_name, pending_key(list_name)
  end

  def self.del_pending(connection, list_name)
    connection.del pending_key(list_name)
  end

  def self.pending_list_sizes
    list_names = %w(abandoned_call_list not_answered_call_list disconnected_call_list wrapped_up_call_list end_answered_by_machine_call_list)
    redis = Redis.new
    list_names.map{ |list| [list, redis.llen(pending_key(list))] }
  end

  def self.multipop(connection, list_name, num)
    num_of_elements = connection.llen list_name
    num_to_pop      = num_of_elements < num ? num_of_elements : num
    result          = []
    num_to_pop.times do |x|
      element = rpoplpush(connection, list_name)
      result << JSON.parse(element) unless element.nil?
    end
    result
  end

  def self.multipush(connection, list_name, data)
    data.each do |element|
      connection.lpush(list_name, element.to_json)
    end
    del_pending(connection, list_name)
  end

  def self.safe_pop(connection, list_name, number)
    data = multipop(connection, list_name, number)
    begin
      yield data
    rescue Resque::TermException => e
      Rails.logger.info "Shutting down. Saving popped data. [safe_pop]"
      ImpactPlatform::Metrics::JobStatus.sigterm(self.to_s.underscore)
      multipush(connection, list_name, data)
      raise
    rescue => exception
      multipush(connection, list_name, data)
      raise
    end
    del_pending(connection, list_name) # clean-up now all have processed successfully
  end

  def self.setup_bitmasks(klass, collection, bitmask_columns)
    columns = klass.column_names
    values  = collection.compact.map do |object|
      columns.map do |column|
        if bitmask_columns.include?(column)
          object.send("#{column}_before_type_cast") 
        else
          object.send(column)
        end
      end
    end
    [columns, values]
  end

  def self.setup_bitmask_hashes(klass, collection, bitmask_columns)
    hashes = []
    columns = klass.column_names
    collection.each do |object|
      hash = {}
      columns.each do |column|
        hash[column] =  if bitmask_columns.include?(column)
                          object.send("#{column}_before_type_cast")
                        else
                          object.send(column)
                        end
      end
      hashes << hash
    end
    hashes
  end

  def self.import_households(households)
    hashes = setup_bitmask_hashes(Household, households, ['blocked'])

    # skip validations - uniqueness validation fails on phone
    # ImportProxy doesn't handle this case
    # the households table has fk constraints as of Dec 2014
    Household.import_hashes(hashes, validate: false)
  end

  def self.import_voters(voters)
    hashes = setup_bitmask_hashes(Voter, voters, ['enabled'])
    Voter.import_hashes(hashes)
  end

  def self.import_call_attempts(call_attempts)
    hashes = call_attempts.map(&:attributes)
    CallAttempt.import_hashes(hashes)
  end

  def self.call_valid?(call)
    call and (call_attempt = call.call_attempt) and call_attempt.household
  end

  def self.process_calls_base(connection, list_name, num)
    safe_pop(connection, list_name, num) do |calls_data|
      calls = Call.where(id: calls_data.map { |c| c['id'] }).includes(call_attempt: [:household]).each_with_object({}) do |call, memo|
        # todo: ^^ change to CallAttempt.where(id: calls_data.map{|c| c['id']}).includes(:household).each_with_object({}) do |call_attempt, memo|
        memo[call.id] = call
      end
      result = calls_data.each_with_object({call_attempts: [], households: []}) do |call_data, memo|
        call = calls[call_data['id'].to_i]
        
        next unless call_valid?(call)
        
        call_attempt = call.call_attempt
        household    = call_attempt.household
        
        yield(call_data, call_attempt)

        household.dialed(call_attempt)

        memo[:call_attempts] << call_attempt
        memo[:households] << household
      end

      import_call_attempts(result[:call_attempts])
      import_households(result[:households])
    end
  end

  def self.abandoned_calls(num)
    process_calls_base($redis_call_flow_connection, "abandoned_call_list", num) do |abandoned_call_data, call_attempt|
      call_attempt.abandoned(abandoned_call_data['current_time'])
    end
  end

  def self.unanswered_calls(num)
    process_calls_base($redis_call_end_connection, "not_answered_call_list", num) do |unanswered_call_data, call_attempt|
      call_attempt.end_unanswered_call(unanswered_call_data['call_status'], unanswered_call_data['current_time'])
    end
  end

  def self.machine_calls(num)
    process_calls_base($redis_call_flow_connection, "end_answered_by_machine_call_list", num) do |unanswered_call_data, call_attempt|
      connect_time      = RedisCallFlow.processing_by_machine_call_hash[unanswered_call_data['id']]
      message_drop_info = RedisCallFlow.get_message_drop_info(unanswered_call_data['id'])
      call_attempt.end_answered_by_machine(connect_time, unanswered_call_data['current_time'], message_drop_info['recording_id'], message_drop_info['drop_type'])
    end
  end

  def self.disconnected_calls(num)
    process_calls_base($redis_call_flow_connection, "disconnected_call_list", num) do |disconnected_call_data, call_attempt|
      call_attempt.disconnect_call(disconnected_call_data['current_time'], disconnected_call_data['recording_duration'],
                                   disconnected_call_data['recording_url'], disconnected_call_data['caller_id'])
    end
  end

  def self.wrapped_up_calls(num)
    updated_call_attempts = []
    updated_voters        = []
    safe_pop($redis_call_flow_connection, "wrapped_up_call_list", num) do |wrapped_up_calls|
      call_attempt_ids = wrapped_up_calls.map{ |c| c['id'] }
      call_attempts    = CallAttempt.includes({household: [:voters]}, :campaign).where(id: call_attempt_ids).each_with_object({}) do |call_attempt, memo|
        memo[call_attempt.id] = call_attempt
      end
      voter_ids = wrapped_up_calls.map{|c| c['voter_id']}
      voters    = Voter.where(id: voter_ids).each_with_object({}) do |voter, memo|
        memo[voter.id] = voter
      end
      wrapped_up_calls.each do |wrapped_up_call|
        call_attempt = call_attempts[wrapped_up_call['id'].to_i]
        voter        = voters[wrapped_up_call['voter_id'].to_i]

        # workaround bug where Voter ID is not saved in redis list
        voterless_call_list = "voterless_calls"

        if voter.nil? and call_attempt.present?
          household = call_attempt.household
          if household.present? and household.voters.count > 0
            voter = household.voters.first
            Rails.logger.error("[PersistCalls:VoterlessCall] Account[#{call_attempt.campaign.account_id}] Campaign[#{call_attempt.campaign_id}] CallAttempt[#{call_attempt.id}] Household[#{call_attempt.household.id}] Wrapped up call did not have VoterID. Auto-assigning Voter[#{voter.id}] from Household.")
          else
            Rails.logger.error("[PersistCalls:VoterlessCall] Account[#{call_attempt.campaign.account_id}] Campaign[#{call_attempt.campaign_id}] CallAttempt[#{call_attempt.id}] Household[#{call_attempt.try(:household).try(:id)}]")
          end
        elsif voter.present? and call_attempt.nil?
          Rails.logger.error("[PersistCalls:VoterlessCall] Voter is present but CallAttempt is nil. Shunting data to #{voterless_call_list}.")
          $redis_call_flow_connection.lpush(voterless_call_list, wrapped_up_call.to_json)
          next
        elsif voter.nil? and call_attempt.nil?
          Rails.logger.error("[PersistCalls:VoterlessCall] Both Voter and CallAttempt are nil. Shunting data to #{voterless_call_list}.")
          $redis_call_flow_connection.lpush(voterless_call_list, wrapped_up_call.to_json)
          next
        end
        # /workaround

        # workaround bug where Voter has no associated household
        houseless_voter_workaround_impossible = false
        if voter.household.nil? and call_attempt.household.present?
          Rails.logger.error("[PersistCalls:HouselessVoters] Account[#{voter.account_id}] Campaign[#{voter.campaign_id}] Voter[#{voter.id}] CallAttempt[#{call_attempt.id}] Household[#{call_attempt.household.id}] Setting Voter#household from CallAttempt#household")
          voter.household_id = call_attempt.household_id
        elsif voter.household.nil? and call_attempt.household.nil?
          houseless_voter_workaround_impossible = true
          Rails.logger.error("[PersistCalls:HouselessVoters] Account[#{voter.account_id}] Campaign[#{voter.campaign_id}] Voter[#{voter.id}] CallAttempt[#{call_attempt.id}] Pushing Voter to houseless list. Both Voter and CallAttempt are houseless.")
          houseless_key          = "houseless_voters:campaign:#{voter.campaign_id}"
          houseless_manifest_key = "houseless_voters:manifest"

          $redis_call_flow_connection.lpush(houseless_key, wrapped_up_call.to_json)
          $redis_call_flow_connection.lpush(houseless_manifest_key, voter.campaign_id)
        end

        unless houseless_voter_workaround_impossible
          call_attempt.wrapup_now(wrapped_up_call['current_time'], wrapped_up_call['caller_type'], voter.id)
          voter.dispositioned(call_attempt)

          updated_call_attempts << call_attempt
          updated_voters        << voter
        end
        # /workaround
      end
      import_call_attempts(updated_call_attempts)
      import_voters(updated_voters)
    end
  end
end
