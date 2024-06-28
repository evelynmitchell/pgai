-------------------------------------------------------------------------------
-- get our anthropic api key

\getenv anthropic_api_key ANTHROPIC_API_KEY
-- set our session local GUC
select set_config('ai.anthropic_api_key', $1, false) is not null as set_anthropic_api_key
\bind :anthropic_api_key
\g

-------------------------------------------------------------------------------
-- register our tests
insert into tests (test)
values
  ('anthropic_generate')
, ('anthropic_generate-no-key')
-- add entries for new tests here!
;

-------------------------------------------------------------------------------
-- anthropic_generate
\echo anthropic_generate
select anthropic_generate
( 'claude-3-5-sonnet-20240620'
, jsonb_build_array
  ( jsonb_build_object
    ( 'role', 'user'
    , 'content', 'Name five famous people from Birmingham, Alabama.'
    )
  )
, _api_key=>$1
) as actual
\bind :anthropic_api_key
\gset

select jsonb_extract_path_text(:'actual'::jsonb, 'content', '0', 'text') is not null and (:'actual'::jsonb)->>'stop_reason' = 'end_turn' as actual
\gset

select result('anthropic_generate', true, :'actual');
\unset actual

-------------------------------------------------------------------------------
-- anthropic_generate-no-key
\echo anthropic_generate-no-key
select anthropic_generate
( 'claude-3-5-sonnet-20240620'
, jsonb_build_array
  ( jsonb_build_object
    ( 'role', 'user'
    , 'content', 'Name five famous people from Birmingham, Alabama.'
    )
  )
) as actual
\gset

select jsonb_extract_path_text(:'actual'::jsonb, 'content', '0', 'text') is not null and (:'actual'::jsonb)->>'stop_reason' = 'end_turn' as actual
\gset

select result('anthropic_generate-no-key', true, :'actual');
\unset actual
