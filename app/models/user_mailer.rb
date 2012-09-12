class UserMailer
  include Rails.application.routes.url_helpers
  include WhiteLabeling

  def initialize
    @uakari = Uakari.new(MAILCHIMP_API_KEY)
  end

  def white_labeled_email(domain)
    email = super(domain)
    @uakari.list_verified_email_addresses["email_addresses"].include?(email) ? email : super("non_existant_domain")
  end

  def deliver_invitation(new_user, current_user)
    link = reset_password_url(protocol: PROTOCOL, :host => "admin.#{current_user.domain}", :reset_code => new_user.password_reset_code)
    @uakari.send_email({
      :track_opens => true,
      :track_clicks => true,
      :message => {
        :subject => I18n.t(:admin_invite_subject, :title => white_labeled_title(current_user.domain)),
        :html => I18n.t(:admin_invite_body_html, :title => white_labeled_title(current_user.domain), :link => link),
        :text => I18n.t(:admin_invite_body_text, :title => white_labeled_title(current_user.domain), :link => link),
        :from_name => white_labeled_title(current_user.domain),
        :from_email => white_labeled_email(current_user.domain),
        :to_email => [new_user.email]
      }
    })
  end

  def reset_password(user)
      emailText="Click here to reset your password<br/> #{ reset_password_url(protocol: PROTOCOL, :host => "admin.#{user.domain}", :reset_code => user.password_reset_code) }"
      response = @uakari.send_email({
          :track_opens => true,
          :track_clicks => true,
          :message => {
              :subject => "#{white_labeled_title(user.domain)} password recovery",
              :html => emailText,
              :text => emailText,
              :from_name => white_labeled_title(user.domain),
              :from_email => white_labeled_email(user.domain),
              :to_email => [user.email]
          }
      })
  end

  def voter_list_upload(response, user_domain, email, voter_list_name)
    unless response['success'].blank?
      subject = I18n.t(:voter_list_upload_succeded_subject, :list_name => voter_list_name)
      content = response['success'].join("<br/>")
    else
      subject = I18n.t(:voter_list_upload_failed_subject, :list_name => voter_list_name)
      content = response['errors'].join("<br/>")
    end
    @uakari.send_email({
      :message => {
        :subject => subject,
        :html => content,
        :from_name => white_labeled_title(user_domain),
        :from_email => white_labeled_email(user_domain),
        :to_email => [email]
      }
    })
  end

  def deliver_download(user, download_link)
    subject = I18n.t(:report_ready_for_download)

    content = "<br/>The report you requested for is ready for download. Follow this link to retrieve it :: <br/> #{download_link}<br/> Please note that this link expires in 24 hours."
    @uakari.send_email({
      :message => {
        :subject => subject,
        :text => content,
        :html => content,
        :from_name => white_labeled_title(user.domain),
        :from_email => white_labeled_email(user.domain),
        :to_email => [user.email]
      }
    })
  end

  def deliver_download_failure(user, campaign, account_id, exception)
    subject = I18n.t(:report_error_occured_subject)
    content = "<br/>#{I18n.t(:report_error_occured)}"
    exception_content = "Campaign: #{campaign.name}  Account Id: #{account.id}. Error details : <br/><br/> #{exception.backtrace.each{|line| "<br/>#{line}"}}"
    @uakari.send_email({ :message => { :subject => subject, :text => content, :html => content, :from_name => white_labeled_title(user.domain), :from_email => white_labeled_email(user.domain), :to_email => [user.email]} })
    @uakari.send_email({ :message => { :subject => subject, :text => exception_content, :html => exception_content, :from_name => white_labeled_title(user.domain), :from_email => 'email@impactdialing.com', :to_email => ['nikhil@activesphere.com','michael@impactdialing.com']} })
  end
end
