--FEATURE-FLAG: text_to_sql

-------------------------------------------------------------------------------
-- _table_def
create or replace function ai._table_def(objid pg_catalog.oid) returns pg_catalog.text
as $func$
declare
    _nspname pg_catalog.name;
    _relname pg_catalog.name;
    _columns pg_catalog.text[];
    _constraints pg_catalog.text[];
    _indexes pg_catalog.text;
    _ddl pg_catalog.text;
begin
    -- names
    select
      n.nspname
    , k.relname
    into strict
      _nspname
    , _relname
    from pg_catalog.pg_class k
    inner join pg_catalog.pg_namespace n
    on (k.relnamespace operator(pg_catalog.=) n.oid)
    where k.oid operator(pg_catalog.=) objid
    ;

    -- columns
    select pg_catalog.array_agg(x.txt order by x.attnum)
    into strict _columns
    from
    (
        select pg_catalog.concat_ws
        ( ' '
        , a.attname
        , pg_catalog.format_type(a.atttypid, a.atttypmod)
        , case when a.attnotnull then 'NOT NULL' else '' end
        , case
            when a.atthasdef
                then pg_catalog.pg_get_expr(d.adbin, d.adrelid)
            when a.attidentity operator(pg_catalog.=) 'd'
                then 'GENERATED BY DEFAULT AS IDENTITY'
            when a.attidentity operator(pg_catalog.=) 'a'
                then 'GENERATED ALWAYS AS IDENTITY'
            when a.attgenerated operator(pg_catalog.=) 's'
                then pg_catalog.format('GENERATED ALWAYS AS (%s) STORED', pg_catalog.pg_get_expr(d.adbin, d.adrelid))
            else ''
          end
        ) as txt
        , a.attnum
        from pg_catalog.pg_attribute a
        left outer join pg_catalog.pg_attrdef d
        on (a.attrelid operator(pg_catalog.=) d.adrelid and a.attnum operator(pg_catalog.=) d.adnum)
        where a.attrelid operator(pg_catalog.=) objid
        and a.attnum operator(pg_catalog.>) 0
        and not a.attisdropped
    ) x;

    -- constraints
    select pg_catalog.array_agg(pg_catalog.pg_get_constraintdef(k.oid, true) order by k.conname)
    into _constraints
    from pg_catalog.pg_constraint k
    where k.conrelid operator(pg_catalog.=) objid
    ;

    -- indexes
    select coalesce(pg_catalog.string_agg(pg_catalog.pg_get_indexdef(i.indexrelid, 0, true), E';\n'), '')
    into strict _indexes
    from pg_catalog.pg_index i
    where i.indrelid operator(pg_catalog.=) objid
    ;

    -- ddl
    select pg_catalog.format(E'CREATE TABLE %I.%I\n( ', _nspname, _relname)
    operator(pg_catalog.||)
    pg_catalog.string_agg(x.line, E'\n, ')
    operator(pg_catalog.||) E'\n);\n'
    operator(pg_catalog.||) _indexes
    into strict _ddl
    from
    (
        select * from pg_catalog.unnest(_columns) line
        union all
        select * from pg_catalog.unnest(_constraints) line
    ) x
    ;

    return _ddl;
end
$func$ language plpgsql stable security invoker
set search_path to pg_catalog, pg_temp
;

-------------------------------------------------------------------------------
-- _text_to_sql_prompt
create or replace function ai._text_to_sql_prompt
( prompt pg_catalog.text
, "limit" pg_catalog.int8 default 5
, objtypes pg_catalog.text[] default null
, max_dist pg_catalog.float8 default null
, catalog_name pg_catalog.text default 'default'
) returns pg_catalog.text
as $func$
declare
    _catalog_id pg_catalog.int4;
    _prompt_emb @extschema:vector@.vector;
    _relevant_obj pg_catalog.jsonb;
    _distinct_tables pg_catalog.oid[];
    _tbl_ctx pg_catalog.text;
    _distinct_views pg_catalog.oid[];
    _view_ctx pg_catalog.text;
    _func_ctx pg_catalog.text;
    _relevant_sql pg_catalog.text;
    _prompt pg_catalog.text;
begin
    -- embed the user prompt
    select
      k.id
    , ai._semantic_catalog_embed
      ( k.id
      , prompt
      )
    into strict
      _catalog_id
    , _prompt_emb
    from ai.semantic_catalog k
    where k.catalog_name operator(pg_catalog.=) _text_to_sql_prompt.catalog_name
    ;

    -- find relevant database objects
    select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r))
    into strict _relevant_obj
    from ai._find_relevant_obj
    ( _catalog_id
    , _prompt_emb
    , "limit"=>"limit"
    , objtypes=>objtypes
    , max_dist=>max_dist
    ) r
    ;

    -- distinct tables
    select pg_catalog.array_agg(distinct objid) into _distinct_tables
    from pg_catalog.jsonb_to_recordset(_relevant_obj) x
    ( objtype pg_catalog.text
    , objid pg_catalog.oid
    )
    where x.objtype in ('table', 'table column')
    ;

    -- construct table contexts
    select pg_catalog.string_agg(x.ctx, E'\n')
    into _tbl_ctx
    from
    (
        select pg_catalog.format
        ( E'<table>\n/*\n# %I.%I\n%s\n%s\n*/\n%s\n</table>'
        , n.nspname
        , k.relname
        , td.description
        , c.cols
        , ai._table_def(k.oid)
        ) as ctx
        from pg_catalog.unnest(_distinct_tables) t
        inner join pg_catalog.pg_class k on (t operator(pg_catalog.=) k.oid)
        inner join pg_catalog.pg_namespace n on (k.relnamespace operator(pg_catalog.=) n.oid)
        left outer join pg_catalog.jsonb_to_recordset(_relevant_obj) td
        ( objtype pg_catalog.text
        , objid pg_catalog.oid
        , description pg_catalog.text
        ) on (td.objtype operator(pg_catalog.=) 'table' and td.objid operator(pg_catalog.=) k.oid)
        left outer join
        (
            select
              c.objid
            , pg_catalog.string_agg
              ( pg_catalog.format(E'## %s\n%s', c.objnames[3], c.description)
              , E'\n'
              ) as cols
            from pg_catalog.jsonb_to_recordset(_relevant_obj) c
            ( objtype pg_catalog.text
            , objid pg_catalog.oid
            , objsubid pg_catalog.int4
            , objnames pg_catalog.name[]
            , description pg_catalog.text
            )
            where c.objtype operator(pg_catalog.=) 'table column'
            group by c.objid
        ) c on (c.objid operator(pg_catalog.=) k.oid)
    ) x
    ;

    -- distinct views
    select pg_catalog.array_agg(distinct objid) into _distinct_views
    from pg_catalog.jsonb_to_recordset(_relevant_obj) x
    ( objtype pg_catalog.text
    , objid pg_catalog.oid
    )
    where x.objtype in ('view', 'view column')
    ;

    -- construct view contexts
    select pg_catalog.string_agg(x.ctx, E'\n')
    into _view_ctx
    from
    (
        select pg_catalog.format
        ( E'<view>\n/*\n# %I.%I\n%s\n%s\n*/\n%s\n</view>'
        , n.nspname
        , k.relname
        , vd.description
        , c.cols
        , pg_catalog.format(E'CREATE VIEW %I.%I AS\n%s\n', n.nspname, k.relname, pg_catalog.pg_get_viewdef(k.oid, true))
        ) as ctx
        from pg_catalog.unnest(_distinct_views) v
        inner join pg_catalog.pg_class k on (v operator(pg_catalog.=) k.oid)
        inner join pg_catalog.pg_namespace n on (k.relnamespace operator(pg_catalog.=) n.oid)
        left outer join pg_catalog.jsonb_to_recordset(_relevant_obj) vd
        ( objtype pg_catalog.text
        , objid pg_catalog.oid
        , description pg_catalog.text
        ) on (vd.objtype operator(pg_catalog.=) 'view' and vd.objid operator(pg_catalog.=) k.oid)
        left outer join
        (
            select
              c.objid
            , pg_catalog.string_agg
              ( pg_catalog.format(E'## %s\n%s', c.objnames[3], c.description)
              , E'\n'
              ) as cols
            from pg_catalog.jsonb_to_recordset(_relevant_obj) c
            ( objtype pg_catalog.text
            , objid pg_catalog.oid
            , objsubid pg_catalog.int4
            , objnames pg_catalog.name[]
            , description pg_catalog.text
            )
            where c.objtype operator(pg_catalog.=) 'view column'
            group by c.objid
        ) c on (c.objid operator(pg_catalog.=) k.oid)
    ) x
    ;

    -- construct function contexts
    select pg_catalog.string_agg(x.fn, E'\n')
    into _func_ctx
    from
    (
        select pg_catalog.format
        ( E'<function>\n/*\n# %I.%I\n%s\n%s*/\n</function>'
        , f.objnames[1]
        , f.objnames[2]
        , f.description
        , pg_catalog.pg_get_functiondef(f.objid)
        ) as fn
        from pg_catalog.jsonb_to_recordset(_relevant_obj) f
        ( objtype pg_catalog.text
        , objid pg_catalog.oid
        , objnames pg_catalog.name[]
        , description pg_catalog.text
        )
        where f.objtype operator(pg_catalog.=) 'function'
    ) x
    ;

    -- find relevant sql examples
    select pg_catalog.string_agg
    ( pg_catalog.format
      ( E'<example-sql>\n/*\n%s\n*/\n%s\n</example-sql>'
      , r.description
      , r.sql
      )
    , E'\n\n'
    ) into _relevant_sql
    from ai._find_relevant_sql
    ( _catalog_id
    , _prompt_emb
    , "limit"=>"limit"
    , max_dist=>max_dist
    ) r
    ;

    -- construct overall prompt
    select pg_catalog.concat_ws
    ( E'\n'
    , 'Consider the following context when responding.'
    , 'Any relevant table, view, and functions descriptions and DDL definitions will appear in <table></table>, <view></view>, and <function></function> tags respectively.'
    , 'Any relevant example SQL statements will appear in <example-sql></example-sql> tags.'
    , _tbl_ctx
    , _view_ctx
    , _func_ctx
    , _relevant_sql
    , 'Respond to the following question with a SQL statement only. Only use syntax and functions that work with PostgreSQL.'
    , 'Q: ' operator(pg_catalog.||) prompt
    , 'A: '
    ) into strict _prompt
    ;

    return _prompt;
end
$func$ language plpgsql stable security invoker
set search_path to pg_catalog, pg_temp
;

-------------------------------------------------------------------------------
-- text_to_sql_openai
create or replace function ai.text_to_sql_openai
( model pg_catalog.text
, api_key pg_catalog.text default null
, api_key_name pg_catalog.text default null
, base_url pg_catalog.text default null
, frequency_penalty pg_catalog.float8 default null
, logit_bias pg_catalog.jsonb default null
, logprobs pg_catalog.bool default null
, top_logprobs pg_catalog.int4 default null
, max_tokens pg_catalog.int4 default null
, n pg_catalog.int4 default null
, presence_penalty pg_catalog.float8 default null
, seed pg_catalog.int4 default null
, stop pg_catalog.text default null
, temperature pg_catalog.float8 default null
, top_p pg_catalog.float8 default null
, openai_user pg_catalog.text default null
) returns pg_catalog.jsonb
as $func$
    select json_object
    ( 'provider': 'openai'
    , 'model': model
    , 'api_key': api_key
    , 'api_key_name': api_key_name
    , 'base_url': base_url
    , 'frequency_penalty': frequency_penalty
    , 'logit_bias': logit_bias
    , 'logprobs': logprobs
    , 'top_logprobs': top_logprobs
    , 'max_tokens': max_tokens
    , 'n': n
    , 'presence_penalty': presence_penalty
    , 'seed': seed
    , 'stop': stop
    , 'temperature': temperature
    , 'top_p': top_p
    , 'openai_user': openai_user
    absent on null
    )
$func$ language sql immutable security invoker
set search_path to pg_catalog, pg_temp
;

-------------------------------------------------------------------------------
-- text_to_sql_ollama
create or replace function ai.text_to_sql_ollama
( model pg_catalog.text
, host pg_catalog.text default null
, keep_alive pg_catalog.text default null
, chat_options pg_catalog.jsonb default null
) returns pg_catalog.jsonb
as $func$
    select json_object
    ( 'provider': 'ollama'
    , 'model': model
    , 'host': host
    , 'keep_alive': keep_alive
    , 'chat_options': chat_options
    absent on null
    )
$func$ language sql immutable security invoker
set search_path to pg_catalog, pg_temp
;

-------------------------------------------------------------------------------
-- text_to_sql_anthropic
create or replace function ai.text_to_sql_anthropic
( model text
, max_tokens int default 1024
, api_key text default null
, api_key_name text default null
, base_url text default null
, timeout float8 default null
, max_retries int default null
, user_id text default null
, stop_sequences text[] default null
, temperature float8 default null
, top_k int default null
, top_p float8 default null
) returns pg_catalog.jsonb
as $func$
    select json_object
    ( 'provider': 'anthropic'
    , 'model': model
    , 'max_tokens': max_tokens
    , 'api_key': api_key
    , 'api_key_name': api_key_name
    , 'base_url': base_url
    , 'timeout': timeout
    , 'max_retries': max_retries
    , 'user_id': user_id
    , 'stop_sequences': stop_sequences
    , 'temperature': temperature
    , 'top_k': top_k
    , 'top_p': top_p
    absent on null
    )
$func$ language sql immutable security invoker
set search_path to pg_catalog, pg_temp
;

-------------------------------------------------------------------------------
-- text_to_sql
create or replace function ai.text_to_sql
( prompt pg_catalog.text
, config pg_catalog.jsonb
, "limit" pg_catalog.int8 default 5
, objtypes pg_catalog.text[] default null
, max_dist pg_catalog.float8 default null
, catalog_name pg_catalog.text default 'default'
) returns pg_catalog.text
as $func$
declare
    _system_prompt pg_catalog.text;
    _user_prompt pg_catalog.text;
    _response pg_catalog.jsonb;
    _sql pg_catalog.text;
begin
    _system_prompt = trim
($txt$
You are an expert database developer and DBA specializing in PostgreSQL.
You will be provided with context about a database model and a question to be answered.
You respond with nothing but a SQL statement that addresses the question posed.
You should not wrap the SQL statement in markdown.
The SQL statement must be valid syntax for PostgreSQL.
SQL features and functions that are built-in to PostgreSQL may be used.
$txt$);

    _user_prompt = ai._text_to_sql_prompt
    ( prompt
    , "limit"=>"limit"
    , objtypes=>objtypes
    , max_dist=>max_dist
    , catalog_name=>catalog_name
    );
    raise log 'prompt: %', _user_prompt;

    case config operator(pg_catalog.->>) 'provider'
        when 'openai' then
            _response = ai.openai_chat_complete
            ( config operator(pg_catalog.->>) 'model'
            , pg_catalog.jsonb_build_array
              ( jsonb_build_object('role', 'system', 'content', _system_prompt)
              , jsonb_build_object('role', 'user', 'content', _user_prompt)
              )
            , api_key=>config operator(pg_catalog.->>) 'api_key'
            , api_key_name=>config operator(pg_catalog.->>) 'api_key_name'
            , base_url=>config operator(pg_catalog.->>) 'base_url'
            , frequency_penalty=>(config operator(pg_catalog.->>) 'frequency_penalty')::pg_catalog.float8
            , logit_bias=>(config operator(pg_catalog.->>) 'logit_bias')::pg_catalog.jsonb
            , logprobs=>(config operator(pg_catalog.->>) 'logprobs')::pg_catalog.bool
            , top_logprobs=>(config operator(pg_catalog.->>) 'top_logprobs')::pg_catalog.int4
            , max_tokens=>(config operator(pg_catalog.->>) 'max_tokens')::pg_catalog.int4
            , n=>(config operator(pg_catalog.->>) 'n')::pg_catalog.int4
            , presence_penalty=>(config operator(pg_catalog.->>) 'presence_penalty')::pg_catalog.float8
            , seed=>(config operator(pg_catalog.->>) 'seed')::pg_catalog.int4
            , stop=>(config operator(pg_catalog.->>) 'stop')
            , temperature=>(config operator(pg_catalog.->>) 'temperature')::pg_catalog.float8
            , top_p=>(config operator(pg_catalog.->>) 'top_p')::pg_catalog.float8
            , openai_user=>(config operator(pg_catalog.->>) 'openai_user')
            );
            raise log 'response: %', _response;
            _sql = pg_catalog.jsonb_extract_path_text(_response, 'choices', '0', 'message', 'content');
        when 'ollama' then
            _response = ai.ollama_chat_complete
            ( config operator(pg_catalog.->>) 'model'
            , pg_catalog.jsonb_build_array
              ( jsonb_build_object('role', 'system', 'content', _system_prompt)
              , jsonb_build_object('role', 'user', 'content', _user_prompt)
              )
            , host=>(config operator(pg_catalog.->>) 'host')
            , keep_alive=>(config operator(pg_catalog.->>) 'keep_alive')
            , chat_options=>(config operator(pg_catalog.->) 'chat_options')
            );
            raise log 'response: %', _response;
            _sql = pg_catalog.jsonb_extract_path_text(_response, 'choices', '0', 'message', 'content');
        when 'anthropic' then
            _response = ai.anthropic_generate
            ( config operator(pg_catalog.->>) 'model'
            , pg_catalog.jsonb_build_array
              ( jsonb_build_object('role', 'user', 'content', _user_prompt)
              )
            , system_prompt=>_system_prompt
            , max_tokens=>(config operator(pg_catalog.->>) 'max_tokens')::pg_catalog.int4
            , api_key=>(config operator(pg_catalog.->>) 'api_key')
            , api_key_name=>(config operator(pg_catalog.->>) 'api_key_name')
            , base_url=>(config operator(pg_catalog.->>) 'base_url')
            , timeout=>(config operator(pg_catalog.->>) 'timeout')::pg_catalog.float8
            , max_retries=>(config operator(pg_catalog.->>) 'max_retries')::pg_catalog.int4
            , user_id=>(config operator(pg_catalog.->>) 'user_id')
            , temperature=>(config operator(pg_catalog.->>) 'temperature')::pg_catalog.float8
            , top_k=>(config operator(pg_catalog.->>) 'top_k')::pg_catalog.int4
            , top_p=>(config operator(pg_catalog.->>) 'top_p')::pg_catalog.float8
            );
            raise log 'response: %', _response;
            _sql = pg_catalog.jsonb_extract_path_text(_response, 'content', '0', 'text');
        else
            raise exception 'unsupported provider';
    end case;
    return _sql;
end
$func$ language plpgsql stable security invoker
set search_path to pg_catalog, pg_temp
;

