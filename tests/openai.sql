-------------------------------------------------------------------------------
-- get our openai api key
-- grab our api key from the environment as a psql variable
\getenv openai_api_key OPENAI_API_KEY
-- set our session local GUC
select set_config('ai.openai_api_key', $1, false) is not null as set_openai_api_key
\bind :openai_api_key
\g

-------------------------------------------------------------------------------
-- register our tests
insert into tests (test)
values
  ('openai_list_models')
, ('openai_list_models-no-key')
, ('openai_tokenize')
, ('openai_detokenize')
, ('openai_embed-1')
, ('openai_embed-1-no-key')
, ('openai_embed-2')
, ('openai_embed-2-no-key')
, ('openai_embed-3')
, ('openai_embed-3-no-key')
, ('openai_embed-4')
, ('openai_embed-4-no-key')
, ('openai_embed-5')
, ('openai_embed-5-no-key')
, ('openai_chat_complete')
, ('openai_chat_complete-no-key')
, ('openai_moderate')
, ('openai_moderate-no-key')
-- add entries for new tests here!
;

-------------------------------------------------------------------------------
-- openai_list_models
\echo openai_list_models
select count(*) as actual
from openai_list_models(_api_key=>$1)
\bind :openai_api_key
\gset

select result('openai_list_models', true, :actual > 0);
\unset actual

-------------------------------------------------------------------------------
-- openai_list_models-no-key
\echo openai_list_models-no-key
select count(*) as actual
from openai_list_models()
\gset

select result('openai_list_models-no-key', true, :actual > 0);
\unset actual

-------------------------------------------------------------------------------
-- openai_tokenize
\echo openai_tokenize
select openai_tokenize('text-embedding-ada-002', 'the purple elephant sits on a red mushroom') as actual
\gset

select result('openai_tokenize', array[1820,25977,46840,23874,389,264,2579,58466]::text, :'actual'::int[]::text);
\unset actual

-------------------------------------------------------------------------------
-- openai_detokenize
\echo openai_detokenize
select openai_detokenize('text-embedding-ada-002', array[1820,25977,46840,23874,389,264,2579,58466]) as actual
\gset

select result('openai_detokenize', 'the purple elephant sits on a red mushroom', :'actual');
\unset actual

-------------------------------------------------------------------------------
-- openai_embed-1
\echo openai_embed-1
select vector_dims
(
    openai_embed
    ( 'text-embedding-ada-002'
    , 'the purple elephant sits on a red mushroom'
    , _api_key=>$1
    )
) as actual
\bind :openai_api_key
\gset

select result('openai_embed-1', 1536, :actual);
\unset actual

-------------------------------------------------------------------------------
-- openai_embed-1-no-key
\echo openai_embed-1-no-key
select vector_dims
(
    openai_embed
    ( 'text-embedding-ada-002'
    , 'the purple elephant sits on a red mushroom'
    )
) as actual
\gset

select result('openai_embed-1-no-key', 1536, :actual);
\unset actual

-------------------------------------------------------------------------------
-- openai_embed-2
\echo openai_embed-2
select vector_dims
(
    openai_embed
    ( 'text-embedding-3-large'
    , 'the purple elephant sits on a red mushroom'
    , _api_key=>$1
    , _dimensions=>768
    )
) as actual
\bind :openai_api_key
\gset

select result('openai_embed-2', 768, :actual);
\unset actual

-------------------------------------------------------------------------------
-- openai_embed-2-no-key
\echo openai_embed-2-no-key
select vector_dims
(
    openai_embed
    ( 'text-embedding-3-large'
    , 'the purple elephant sits on a red mushroom'
    , _dimensions=>768
    )
) as actual
\gset

select result('openai_embed-2-no-key', 768, :actual);
\unset actual

-------------------------------------------------------------------------------
-- openai_embed-3
\echo openai_embed-3
select vector_dims
(
    openai_embed
    ( 'text-embedding-3-large'
    , 'the purple elephant sits on a red mushroom'
    , _api_key=>$1
    , _user=>'bob'
    )
) as actual
\bind :openai_api_key
\gset

select result('openai_embed-3', 3072, :actual);
\unset actual

-------------------------------------------------------------------------------
-- openai_embed-3-no-key
\echo openai_embed-3-no-key
select vector_dims
(
    openai_embed
    ( 'text-embedding-3-large'
    , 'the purple elephant sits on a red mushroom'
    , _user=>'bob'
    )
) as actual
\gset

select result('openai_embed-3-no-key', 3072, :actual);
\unset actual

-------------------------------------------------------------------------------
-- openai_embed-4
\echo openai_embed-4
select sum(vector_dims(embedding)) as actual
from openai_embed
( 'text-embedding-3-large'
, array['the purple elephant sits on a red mushroom', 'timescale is postgres made powerful']
, _api_key=>$1
)
\bind :openai_api_key
\gset

select result('openai_embed-4', 6144, :actual);
\unset actual

-------------------------------------------------------------------------------
-- openai_embed-4-no-key
\echo openai_embed-4-no-key
select sum(vector_dims(embedding)) as actual
from openai_embed
( 'text-embedding-3-large'
, array['the purple elephant sits on a red mushroom', 'timescale is postgres made powerful']
)
\gset

select result('openai_embed-4-no-key', 6144, :actual);
\unset actual

-------------------------------------------------------------------------------
-- openai_embed-5
\echo openai_embed-5
select vector_dims
(
    openai_embed
    ( 'text-embedding-ada-002'
    , array[1820,25977,46840,23874,389,264,2579,58466]
    , _api_key=>$1
    )
) as actual
\bind :openai_api_key
\gset

select result('openai_embed-5', 1536, :actual);
\unset actual

-------------------------------------------------------------------------------
-- openai_embed-5-no-key
\echo openai_embed-5-no-key
select vector_dims
(
    openai_embed
    ( 'text-embedding-ada-002'
    , array[1820,25977,46840,23874,389,264,2579,58466]
    )
) as actual
\gset

select result('openai_embed-5-no-key', 1536, :actual);
\unset actual

-------------------------------------------------------------------------------
-- openai_chat_complete
\echo openai_chat_complete
select openai_chat_complete
( 'gpt-4o'
, jsonb_build_array
  ( jsonb_build_object('role', 'system', 'content', 'you are a helpful assistant')
  , jsonb_build_object('role', 'user', 'content', 'what is the typical weather like in Alabama in June')
  )
, _api_key=>$1
) as actual
\bind :openai_api_key
\gset

select jsonb_extract_path_text(:'actual'::jsonb, 'choices', '0', 'message', 'content') is not null as actual
\gset

select result('openai_chat_complete', true, :'actual');
\unset actual

-------------------------------------------------------------------------------
-- openai_chat_complete-no-key
\echo openai_chat_complete-no-key
select openai_chat_complete
( 'gpt-4o'
, jsonb_build_array
  ( jsonb_build_object('role', 'system', 'content', 'you are a helpful assistant')
  , jsonb_build_object('role', 'user', 'content', 'what is the typical weather like in Alabama in June')
  )
) as actual
\gset

select jsonb_extract_path_text(:'actual'::jsonb, 'choices', '0', 'message', 'content') is not null as actual
\gset

select result('openai_chat_complete-no-key', true, :'actual');
\unset actual

-------------------------------------------------------------------------------
-- openai_moderate
\echo openai_moderate
select openai_moderate
( 'text-moderation-stable'
, 'I want to kill them.'
, _api_key=>$1
) as actual
\bind :openai_api_key
\gset

select jsonb_extract_path_text(:'actual'::jsonb, 'results', '0', 'flagged')::bool as actual
\gset

select result('openai_moderate', true, :'actual');
\unset actual

-------------------------------------------------------------------------------
-- openai_moderate-no-key
\echo openai_moderate-no-key
select openai_moderate
( 'text-moderation-stable'
, 'I want to kill them.'
) as actual
\gset

select jsonb_extract_path_text(:'actual'::jsonb, 'results', '0', 'flagged')::bool as actual
\gset

select result('openai_moderate-no-key', true, :'actual');
\unset actual

-------------------------------------------------------------------------------
