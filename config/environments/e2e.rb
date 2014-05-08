HOST = 'localhost'
PORT = 3000

MANDRILL_API_KEY='qlYdRXlyROwaN9Tqk1QrhA'

require 'capybara/rails'

ImpactDialing::Application.configure do
  # Settings specified here will take precedence over those in config/environment.rb

  # The test environment is used exclusively to run your application's
  # test suite.  You never need to work with it otherwise.  Remember that
  # your test database is "scratch space" for the test suite and is wiped
  # and recreated between test runs.  Don't rely on the data there!
  config.cache_classes = true

  # Log error messages when you accidentally call methods on nil.
  config.whiny_nils = true

  # Show full error reports and disable caching
  config.consider_all_requests_local = true
  config.action_controller.perform_caching             = false

  # Disable request forgery protection in test environment
  config.action_controller.allow_forgery_protection    = false

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  config.active_support.deprecation = :log

  # Use SQL instead of Active Record's schema dumper when creating the test database.
  # This is necessary if your schema can't be completely dumped by the schema dumper,
  # like if you have constraints or database-specific column types
  # config.active_record.schema_format = :sql

  require 'shoulda'
  require 'factory_girl'
  # require 'simplecov'

  # SimpleCov.start

  PUSHER_APP_ID="blah"
  PUSHER_KEY="blahblah"
  PUSHER_SECRET="blahblahblah"
  TWILIO_ACCOUNT="blahblahblah"
  TWILIO_AUTH="blahblahblah"
  TWILIO_APP_SID="blahdahhahah"
  TWILIO_ERROR = "blah"
  HOLD_MUSIC_URL = "hold_music"
  MONITOR_TWILIO_APP_SID="blah"
  STRIPE_PUBLISHABLE_KEY = "pk_test_C7afhsETXQncQqcBQ2Hr2f0M"
  STRIPE_SECRET_KEY = "sk_test_EHZciy2zvJc6UelOAMdFX6wX"
end