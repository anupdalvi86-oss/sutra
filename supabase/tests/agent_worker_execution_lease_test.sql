begin;
select no_plan();

select ok(not has_function_privilege('anon',
  'public.sutra_acquire_agent_worker_execution_lease(text)','execute'),
  'anon cannot acquire the internal worker execution lease');
select ok(not has_function_privilege('authenticated',
  'public.sutra_release_agent_worker_execution_lease(text)','execute'),
  'authenticated cannot release the internal worker execution lease');
select is(public.sutra_acquire_agent_worker_execution_lease('sutra-worker-12345678'),true,
  'first worker acquires one bounded inference slot');
select is(public.sutra_acquire_agent_worker_execution_lease('sutra-worker-abcdefgh'),true,
  'second worker acquires the second bounded inference slot');
select is(public.sutra_acquire_agent_worker_execution_lease('sutra-worker-87654321'),false,
  'a third worker cannot exceed the two-slot execution ceiling');
select is(public.sutra_release_agent_worker_execution_lease('sutra-worker-87654321'),false,
  'a different worker cannot release the active lease');
select is(public.sutra_release_agent_worker_execution_lease('sutra-worker-12345678'),true,
  'the owner releases its lease after finishing its run');
select is(public.sutra_acquire_agent_worker_execution_lease('sutra-worker-87654321'),true,
  'the next worker proceeds after a slot is released');
update public.agent_worker_execution_leases
  set lease_expires_at=clock_timestamp()-interval '1 second'
  where slot_no=1;
select is(public.sutra_acquire_agent_worker_execution_lease('sutra-worker-12345678'),true,
  'an expired lease recovers after a crashed worker');
select is((select worker_id from public.agent_worker_execution_leases where slot_no=1),
  'sutra-worker-12345678','expired lease recovery assigns ownership atomically');
select throws_ok($$select public.sutra_acquire_agent_worker_execution_lease('bad-worker')$$,
  '22023',null,'malformed worker identity cannot acquire the lease');

select * from finish();
rollback;
