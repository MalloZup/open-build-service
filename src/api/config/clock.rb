require File.dirname(__FILE__) + '/boot'
require File.dirname(__FILE__) + '/environment'

# make sure our event is loaded first - the clockwork::event is *not* ours
require 'event'

require 'clockwork'
include Clockwork

every(30.seconds, 'status.refresh') do
  Rails.logger.debug "Refresh worker status"
  c = StatusController.new
  # this should be fast, so don't delay
  c.update_workerstatus_cache
end
 
every(1.hour, 'refresh issues') do
  IssueTracker.all.each do |t|
    next unless t.enable_fetch
    t.delay.update_issues
  end
end

every(1.hour, 'accept requests') do
  User.current = User.get_default_admin
  BsRequest.to_accept.each do |r|
    r.delay.auto_accept
  end
end

every(49.minutes, 'rescale history') do
  # we just pick the first to have a model to .delay
  StatusHistory.first.delay.rescale
end

every(1.day, 'optimize history', thread: true) do
  sql = ActiveRecord::Base.connection
  sql.execute "optimize table status_histories;"
end

every(5.minutes, 'check last events') do
  bi = BackendInfo.first
  # save *something* to have a model we can delay on
  BackendInfo.lastevents_nr = 1 unless bi
  BackendInfo.first.delay.update_last_events 
end

every(30.seconds, 'send notifications') do
  Event::NotifyBackends.trigger_delayed_sent
end

every(17.seconds, 'fetch notificatoins', thread: true) do
  # this will return if there is already a thread running
  UpdateNotificationEvents.new.perform
end

# We want Sphinx to be started everytime clockworkd starts. Scheduling a restart
# every week ensures that initial start and doesn't really hurt. Not the
# cleanest solution, but avoids creating/modifying init.d scripts
every(1.week, 're(start) sphinx', thread: true) do
  interface = ThinkingSphinx::RakeInterface.new
  interface.stop
  interface.start
end

every(1.hour, 'reindex sphinx', thread: true) do
  ThinkingSphinx::RakeInterface.new.index
end
