--- Tunables for debugging
--\timing on
--set enable_hashjoin to off;
--set enable_seqscan to off;

\pset border 0
\pset format unaligned
\pset tuples_only on
begin read only;
-- This one is for debugging using http://tatiyants.com/pev/#/plans/new
--#explain ( analyze, costs, verbose, buffers, format json )
--explain ( analyze, costs, verbose, buffers )
with params as (
    select
        27.61649608612061 :: float  as minlon,
        53.85379229563698 :: float  as minlat,
        27.671985626220707 :: float as maxlon,
        53.886459293813054 :: float as maxlat
), direct_nodes as (
    select n.id
    from
        current_nodes n,
        params p
    where
        point(longitude :: float / 1e7 :: float, latitude :: float / 1e7 :: float) <@
        box(point(minlon, minlat), point(maxlon, maxlat))
        -- and n.tile in (...) - dropped in favor of SP-GiST, can be returned
        --         and n.latitude between minlat and maxlat
        --         and n.longitude between minlon and maxlon
        and n.visible
), all_request_ways as (
    select distinct c.way_id as id
    from
        direct_nodes n
        join current_way_nodes c on (c.node_id = n.id)
), all_request_nodes as (
    select distinct id
    from (
             select c.node_id as id
             from
                 all_request_ways w
                 join current_way_nodes c on (c.way_id = w.id)
             union
             select n.id
             from direct_nodes n
         ) nodes
), relations_from_ways_and_nodes as (
    select distinct on (id)
        r.id,
        r.visible,
        r.version,
        r.changeset_id,
        r.timestamp
    from
        (
            select
                id,
                'Way' :: nwr_enum as type
            from all_request_ways
            union all
            select
                id,
                'Node' :: nwr_enum as type
            from all_request_nodes
        ) wn
        join current_relation_members m on (wn.id = m.member_id and wn.type = m.member_type)
        join current_relations r on (m.relation_id = r.id)
    where r.visible
), all_request_relations as (
    select
        r.id,
        r.visible,
        r.version,
        r.changeset_id,
        r.timestamp
    from relations_from_ways_and_nodes r
    union
    select
        r.id,
        r.visible,
        r.version,
        r.changeset_id,
        r.timestamp
    from relations_from_ways_and_nodes r2
        join current_relation_members rm on (r2.id = rm.member_id and rm.member_type = 'Relation')
        join current_relations r on (r.id = rm.relation_id)
    where r.visible
), all_request_users as (
    select
        distinct on (changeset_id)
        changeset_id,
        u.display_name as name,
        u.id           as uid
    from
        (
            select changeset_id
            from all_request_relations
        ) as rc
        join changesets c on (rc.changeset_id = c.id)
        left join users u on (c.user_id = u.id and u.data_public)
    order by changeset_id
)
select line
from (
    -- XML header
    select
        '<?xml version="1.0" encoding="UTF-8"?><osm version="0.6" generator="FastMAP" copyright="OpenStreetMap and contributors" attribution="http://www.openstreetmap.org/copyright" license="http://opendatacommons.org/licenses/odbl/1-0/">' :: text as line
    union all
    -- bounds header
    select xmlelement(name bounds, xmlattributes (minlat, minlon, maxlat, maxlon)) :: text as line
from params p
union all
-- nodes
select line :: text
from (
         select get_node_by_id(n.id) :: xml as line
         from all_request_nodes n
         order by n.id
     ) nodes
union all
-- ways
select line :: text
from (
         select get_way_by_id(w.id) :: xml as line
         from all_request_ways w
         order by w.id
     ) ways
union all
-- relations
select line :: text
from
    (
        select
            xmlelement(
                name relation,
                xmlattributes (
                id as id,
                visible as visible,
                version as version,
                r.changeset_id as changeset,
                to_char(timestamp, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as timestamp,
                u.name as user,
                u.uid as uid
            ),
            rt.tags,
            mbr.nodes
    ) line
from all_request_relations r
join all_request_users u on (r.changeset_id = u.changeset_id)
join lateral (
select xmlagg(
xmlelement(
name tag,
xmlattributes (
k as k,
v as v
)
)
) as tags
from current_relation_tags t
where t.relation_id = r.id
) rt on true
join lateral (
select xmlagg(
xmlelement(
name member,
xmlattributes (
case member_type
when 'Way' then 'way'
when 'Relation' then 'relation'
when 'Node' then 'node'
end as type,
member_id as ref,
member_role as role
)
)
order by sequence_id
) as nodes
from current_relation_members t
where t.relation_id = r.id
) mbr on true
order by r.id
) relations
union all
-- XML footer
select '</osm>'
) repsonse;
commit;