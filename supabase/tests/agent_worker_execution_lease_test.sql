begin;
select no_plan();

select ok(not has_function_privilege('anon',
  'public.sutra_acquire_agent_worker_execution_lease(text)','execute'),
  'anon cannot acquire the internal worker execution lease');
select ok(not has_function_privilege('authenticated',
  'public.sutra_release_agent_worker_execution_lease(text)','execute'),
  'authenticated cannot release the internal worker execution lease');
select is(public.sutra_acquire_agent_worker_execution_lease('sutra-worker-12345678'),true,
  'first worker acquires the shared inference execution slot');
select is(public.sutra_acquire_agent_worker_execution_lease('sutra-worker-abcdefgh'),false,
  'a second worker cannot execute provider work concurrently');
select is(public.sutra_release_agent_worker_execution_lease('sutra-worker-abcdefgh'),false,
  'a different worker cannot release the active lease');
select is(public.sutra_release_agent_worker_execution_lease('sutra-worker-12345678'),true,
  'the owner releases the lease after finishing its run');
select is(public.sutra_acquire_agent_worker_execution_lease('sutra-worker-abcdefgh'),true,
  'the next worker proceeds after release');
update public.agent_worker_execution_leases
  set lease_expires_at=clock_timestamp()-interval '1 second'
  where lease_key='agent-worker';
select is(public.sutra_acquire_agent_worker_execution_lease('sutra-worker-87654321'),true,
  'an expired lease recovers after a crashed worker');
select is((select worker_id from public.agent_worker_execution_leases where lease_key='agent-worker'),
  'sutra-worker-87654321','expired lease recovery assigns ownership atomically');
select throws_ok($$select public.sutra_acquire_agent_worker_execution_lease('bad-worker')$$,
  '22023',null,'malformed worker identity cannot acquire the lease');

select * from finish();
rollback;
