-- Channel authorization probes do not necessarily set messages.private.
-- Enforce the authenticated work role, extension and exact topic. Delivery is
-- still private: both realtime.send and the browser channel use private=true.
alter policy yt_work_receive_refresh_signals on realtime.messages
using (
 extension='broadcast'
 and topic=(select realtime.topic())
 and (
  (topic in ('yt-work-orders','yt-work-freeflow') and (select private.yt_pos_work_staff()))
  or (topic='yt-work-bell' and (select private.yt_pos_work_cashier()))
 )
);
