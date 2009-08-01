--#######################################################
-- Export results for graphing

--    elt(mod(floor(study_hour/100000),100), "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December") as month, 
-- concat(mod(floor(study_hour/100000),100), "/01/", period, " ", mod(floor(study_hour/1000),100), ":00") as study_time,

-- Determine investment period length
set @first_period  := (select min( period) from gen_cap);
set @second_period := (select min(period) from gen_cap where period != @first_period );
set @period_length := (@second_period - @first_period);
set @last_period := (select max(period) from gen_cap);


-- total generation each hour
drop table if exists gen_hourly_summary;
create table gen_hourly_summary
  select carbon_cost, period, study_date, study_hour, hours_in_sample, mod(floor(study_hour/100000),100) as month, 
    elt(mod(floor(study_hour/100000),100), "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec") as month_name, 
    6*floor(mod(study_hour, 100000)/6000) as quarter_of_day,
    mod(floor(study_hour/1000),100) as hour_of_day, 
    case when site in ("Transmission Losses", "Load", "Fixed Load") then "Fixed Load"
         when site = "Dispatched Load" then site
         when fuel like "Hydro%" then fuel
         when new then concat("New ", technology)
         else concat("Existing ", fuel, if(cogen, " Cogen", ""))
    end as source,
    sum(power) as power
    from dispatch
    where site <> "Transmission"
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10;
alter table gen_hourly_summary add index (source, study_hour);
-- I used to add any hours with pumping to the load, and set the hydro to zero
-- instead, now I just reverse the sign of the pumping, to make a quasi-load
update gen_hourly_summary set power=-power where source="Hydro Pumping";


-- total generation each hour
drop table if exists gen_hourly_summary_la;
create table gen_hourly_summary_la
  select carbon_cost, period, load_area, study_date, study_hour, hours_in_sample, mod(floor(study_hour/100000),100) as month, 
    elt(mod(floor(study_hour/100000),100), "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec") as month_name, 
    6*floor(mod(study_hour, 100000)/6000) as quarter_of_day,
    mod(floor(study_hour/1000),100) as hour_of_day, 
    case when site in ("Transmission Losses", "Load", "Fixed Load") then "Fixed Load"
         when site = "Dispatched Load" then site
         when fuel like "Hydro%" then fuel
         when new then concat("New ", technology)
         else concat("Existing ", fuel, if(cogen, " Cogen", ""))
    end as source,
    sum(power) as power
    from dispatch
    where site <> "Transmission"
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11;
alter table gen_hourly_summary_la 
	add index (carbon_cost), 
	add index (source, study_hour), 
	add index (study_hour), 
	add index (load_area);
-- I used to add any hours with pumping to the load, and set the hydro to zero
-- instead, now I just reverse the sign of the pumping, to make a quasi-load
update gen_hourly_summary_la set power=-power where source="Hydro Pumping";


-- total generation each period
-- this pools the dispatchable and fixed loads, and the regular and pumped hydro
drop table if exists gen_summary;
create table gen_summary
  select concat(period, "-", period+@period_length-1) as period, carbon_cost, 
    case when site in ("Transmission Losses", "Load", "Fixed Load", "Dispatched Load") then "System Load"
         when fuel like "Hydro%" then "Hydro"
         when new then concat("New ", technology)
         else concat("Existing ", fuel, if(cogen, " Cogen", ""))
    end as source,
    sum(power*hours_in_sample)/(8760*@period_length) as avg_power
    from dispatch
    where site <> "Transmission"
    group by 1, 2, 3;

-- total generation each period by load area
-- this pools the dispatchable and fixed loads, and the regular and pumped hydro
drop table if exists gen_summary_la;
create table gen_summary_la
  select concat(period, "-", period+@period_length-1) as period, carbon_cost, load_area, 
    case when site in ("Transmission Losses", "Load", "Fixed Load", "Dispatched Load") then "System Load"
         when fuel like "Hydro%" then "Hydro"
         when new then concat("New ", technology)
         else concat("Existing ", fuel, if(cogen, " Cogen", ""))
    end as source,
    sum(power*hours_in_sample)/(8760*@period_length) as avg_power
    from dispatch
    where site <> "Transmission"
    group by 1, 2, 3, 4;

-- cross-tab table showing total generation in the final period, by load zone and source
-- (used to make maps)
-- this makes a comma-separated list of values, which can then be exported normally (tab delimited)
-- and then read as if it were comma-separated
drop table if exists grouptots;
create table grouptots
  select load_area, carbon_cost, 
  case when site in ("Transmission Losses", "Load", "Fixed Load", "Dispatched Load") then "System Load"
       when fuel like "Hydro%" then "Hydro"
       when new then concat("New ", technology)
       else concat("Existing ", fuel, if(cogen, " Cogen", ""))
  end as source,
  sum(power*hours_in_sample)/(8760*@period_length) as avg_power
  from dispatch
  where site <> "Transmission" and period=@last_period
  group by 1, 2, 3;
-- add dummy records for any load_area - source combinations that are missing
insert into grouptots 
  select load_area, carbon_cost, source, 0 as avg_power
  from (select distinct load_area from grouptots) p join (select distinct source from grouptots) s join (select distinct carbon_cost from grouptots) c
  where (load_area, source, carbon_cost) not in (select distinct load_area, source, carbon_cost from grouptots);
-- make the final cross-tabulated table
drop table if exists gen_by_load_area;
create table gen_by_load_area
  select concat("load_area,x_utm,y_utm,", group_concat(distinct replace(source, " ", "_") order by source separator ",")) as row from grouptots
  union
  select concat(a.load_area, ",", x_utm, ",", y_utm, ",", group_concat(avg_power order by source separator ",")) as row 
    from grouptots t join wecc.load_area a on a.load_area=replace(t.load_area, "_", " ") group by a.load_area;

-- cross-tab of percentage of power coming from each source during the final period, by carbon_tax
-- note: these are indexed relative to the $0 system load; results may exceed this for higher carbon costs due to transmission losses (small) and surplus power
create temporary table system_load_by_carbon_cost
	select carbon_cost, sum(power*hours_in_sample) as system_load from dispatch where period=@last_period and site in ("Transmission Losses", "Load", "Fixed Load", "Dispatched Load");
drop table if exists grouptots;
create table grouptots
  select dispatch.carbon_cost,
  case when site in ("Transmission Losses", "Load", "Fixed Load", "Dispatched Load") then "System Load"
       when fuel like "Hydro%" then "Hydro"
       when new then concat("New ", technology)
       else concat("Existing ", fuel, if(cogen, " Cogen", ""))
  end as source,
  sum(power*hours_in_sample) / system_load as share
  from dispatch, system_load_by_carbon_cost
  where site <> "Transmission" and period=@last_period and system_load_by_carbon_cost.carbon_cost = dispatch.carbon_cost
  group by 1, 2;
-- add dummy records for any load_area - source combinations that are missing
insert into grouptots 
  select carbon_cost, source, 0 as share
  from (select distinct carbon_cost from grouptots) p join (select distinct source from grouptots) s
  where (carbon_cost, source) not in (select distinct carbon_cost, source from grouptots);
-- make the final cross-tabulated table
drop table if exists gen_source_share_by_carbon_cost;
create table gen_source_share_by_carbon_cost
  select concat("carbon_cost,", group_concat(distinct source order by source separator ",")) as row from grouptots
  union
  select concat(carbon_cost, ",", group_concat(share order by source separator ",")) as row 
    from grouptots t group by carbon_cost;

-- cross-tab of installed capacity from each source during the final period, by carbon_tax
drop table if exists grouptots;
create table grouptots
  select carbon_cost,
  case when site in ("Transmission Losses", "Load", "Fixed Load", "Dispatched Load") then "System Load"
       when fuel like "Hydro%" then "Hydro"
       when new then concat("New ", technology)
       else concat("Existing ", fuel, if(cogen, " Cogen", ""))
  end as source,
  sum(capacity) as capacity
  from gen_cap
  where site <> "Transmission" and period=@last_period
  group by 1, 2;
-- add dummy records for any load_area - source combinations that are missing
insert into grouptots 
  select carbon_cost, source, 0 as capacity
  from (select distinct carbon_cost from grouptots) p join (select distinct source from grouptots) s
  where (carbon_cost, source) not in (select distinct carbon_cost, source from grouptots);
-- make the final cross-tabulated table
drop table if exists gen_source_capacity_by_carbon_cost;
create table gen_source_capacity_by_carbon_cost
  select concat("carbon_cost,", group_concat(distinct source order by source separator ",")) as row from grouptots
  union
  select concat(carbon_cost, ",", group_concat(capacity order by source separator ",")) as row 
    from grouptots t group by carbon_cost;

-- We don't need this table anymore. We can't make it a temporary table because some of the self-join operations don't work on temp tables due to a mysql bug.
drop table if exists grouptots;


-- capacity each period
drop table if exists gen_cap_summary;
create table gen_cap_summary
  select concat(period, "-", period+@period_length-1) as period, carbon_cost, 
    case when site in ("Transmission Losses", "Load", "Fixed Load", "Dispatched Load") then "System Load"
         when fuel like "Hydro%" then "Hydro"
         when new then concat("New ", technology)
         else concat("Existing ", fuel, if(cogen, " Cogen", ""))
    end as source,
      sum(capacity) as capacity
    from gen_cap
    where site <> "Transmission"
    group by 1, 2, 3
  union 
  select concat(period, "-", period+@period_length-1) as period, carbon_cost, "Peak Load" as source, max(power) as capacity 
    from gen_hourly_summary where source="Fixed Load"
    group by 1, 2, 3
  union 
  select concat(period, "-", period+@period_length-1) as period, carbon_cost, "Reserve Margin" as source, 1.15 * max(power) as capacity 
    from gen_hourly_summary where source="Fixed Load"
    group by 1, 2, 3;
-- if a technology is not developed, it doesn't show up in the generator list,
-- but it's convenient to have it in the list anyway
insert into gen_cap_summary (period, carbon_cost, source, capacity)
  select period, carbon_cost, source, 0 from gen_summary 
    where source <> "System Load" and (period, carbon_cost, source) not in (select period, carbon_cost, source from gen_cap_summary);

-- ------------------------------
-- Insert dummy records into the transmission table - basically, put a 0 power transfer in each hour 
-- where power could have been sent across a line, but wasn't
-- insert into transmission (period, carbon_cost, source, capacity)
--   select period, carbon_cost, source, 0 from gen_summary 
--     where source <> "System Load" and (period, carbon_cost, source) not in (select period, carbon_cost, source from gen_cap_summary);
-- 
--   scenario varchar(25),
--   carbon_cost double,
--   period int,
--   load_area_receive varchar(20),
--   load_area_from varchar(20),
--   study_date int,
--   study_hour int,
--   power double,
--   hours_in_sample smallint
-- 
-- 
-- -- List of distinct transmission lines (both ways)
-- SELECT distinct scenario, carbon_cost, period, start as load_area_receive, end as load_area_from [study_data & hour], 0 as power, [hours_in_sample] FROM Rslts_mini_AbvGrd.trans_cap t where period = @last_period and (new + trans_mw) > 0 order by start, end
-- 	UNION
-- SELECT distinct scenario, carbon_cost, period, end as load_area_receive, start as load_area_from FROM Rslts_mini_AbvGrd.trans_cap t where period = @last_period and (new + trans_mw) > 0 order by start, end

-- emission reductions vs. carbon cost
-- 1990 electricity emissions from table 6 at http://www.climatechange.ca.gov/policies/greenhouse_gas_inventory/index.html
--   (the table is in http://www.energy.ca.gov/2006publications/CEC-600-2006-013/figures/Table6.xls)
-- that may not include cogen plants?
-- 1990 california gasoline consumption from eia: http://www.eia.doe.gov/emeu/states/sep_use/total/use_tot_ca.html
-- gasoline emission coefficient from http://www.epa.gov/OMS/climate/820f05001.htm
-- Bug!   Currently, this select is broken because we are not running scenarios with a carbon cost of 0 :/
--        Also, the denominator of 8 may reflect a past scenario that used 8 years per investment period.
set @base_co2_tons := (select sum(co2_tons*hours_in_sample)/8 from dispatch where carbon_cost=0 and period=@last_period);
set @co2_tons_1990 := 86700000; # electricity generation
-- set @co2_tons_1990 := @co2_tons_1990 + 0.5*305983000*42*8.8/1000;  # vehicle fleet

-- The denominator of 8 may reflect a past scenario that used 8 years per investment period. 
-- Currently, the co2_tons_reduced & co2_share_reduced are broken b/c @base_co2_tons is returning NULL. See note above.
drop table if exists co2_CC;
create table co2_cc 
  select carbon_cost, sum(co2_tons*hours_in_sample)/8 as co2_tons, 
    @base_co2_tons-sum(co2_tons*hours_in_sample)/8 as co2_tons_reduced, 
    1-sum(co2_tons*hours_in_sample)/8/@base_co2_tons as co2_share_reduced, 
    @co2_tons_1990-sum(co2_tons*hours_in_sample)/8 as co2_tons_reduced_1990,
    1-sum(co2_tons*hours_in_sample)/8/@co2_tons_1990 as co2_share_reduced_1990
  from dispatch where period = @last_period group by 1;

-- average power costs, for each study period, for each carbon tax
-- (this should probably use a discounting method for the MWhs, 
-- since the costs are already discounted to the start of each period,
-- but electricity production is spread out over time. But the main model doesn't do that
-- so I don't do it here either.)
drop temporary table if exists tloads;
create temporary table tloads
  select period, carbon_cost, sum(power*hours_in_sample) as load_mwh
  from dispatch
  where site in ("Transmission Losses", "Load", "Fixed Load", "Dispatched Load")
  group by 1, 2;
alter table tloads add index pcl (period, carbon_cost, load_mwh);

drop temporary table if exists tfixed_costs_gen;
create temporary table tfixed_costs_gen
  select period, carbon_cost, sum(fixed_cost) as fixed_cost_gen
    from gen_cap group by 1, 2;
alter table tfixed_costs_gen add index pc (period, carbon_cost);
drop temporary table if exists tfixed_costs_trans;
create temporary table tfixed_costs_trans
  select period, carbon_cost, sum(fixed_cost) as fixed_cost_trans
    from trans_cap group by 1, 2;
alter table tfixed_costs_trans add index pc (period, carbon_cost);
drop temporary table if exists tfixed_costs_local_td;
create temporary table tfixed_costs_local_td
  select period, carbon_cost, sum(fixed_cost) as fixed_cost_local_td
    from local_td_cap group by 1, 2;
alter table tfixed_costs_local_td add index pc (period, carbon_cost);

drop temporary table if exists tvariable_costs;
create temporary table tvariable_costs
  select period, carbon_cost, sum(fuel_cost_tot*hours_in_sample) as fuel_cost, 
    sum(carbon_cost_tot*hours_in_sample) as carbon_cost_tot,
    sum(variable_o_m_tot*hours_in_sample) as variable_o_m
    from dispatch group by 1, 2;
alter table tvariable_costs add index pc (period, carbon_cost);

drop table if exists power_cost;
create table power_cost
  select l.period, l.carbon_cost, load_mwh, 
    fixed_cost_gen, fixed_cost_trans, fixed_cost_local_td,
    fuel_cost, carbon_cost_tot, variable_o_m,
    fixed_cost_gen + fixed_cost_trans + fixed_cost_local_td 
      + fuel_cost + carbon_cost_tot + variable_o_m as total_cost
  from tloads l 
    join tfixed_costs_gen using (period, carbon_cost)
    join tfixed_costs_trans using (period, carbon_cost)
    join tfixed_costs_local_td using (period, carbon_cost)
    join tvariable_costs using (period, carbon_cost);
alter table power_cost add column cost_per_mwh double;
update power_cost set cost_per_mwh = total_cost/load_mwh;

