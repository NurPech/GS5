-- Gemeinschaft 5 module: call router class
-- (c) AMOOMA GmbH 2013
-- 

module(...,package.seeall)

Router = {}

-- create route object
function Router.new(self, arg)
  require 'common.str';
  require 'common.array';
  arg = arg or {}
  object = arg.object or {}
  setmetatable(object, self);
  self.__index = self;
  self.class = 'router';
  self.log = arg.log;
  self.database = arg.database;
  self.routes = arg.routes or {};
  self.caller = arg.caller;
  self.variables = arg.variables or {};
  self.log_details = arg.log_details;
  self.routing_tables = {};
  return object;
end


function Router.read_table(self, table_name, force_reload)
  if not force_reload and self.routing_tables[table_name] then
    return self.routing_tables[table_name];
  end

  local routing_table = {};

  local sql_query = 'SELECT * \
    FROM `call_routes` `a` \
    JOIN `route_elements` `b` ON `a`.`id` = `b`.`call_route_id`\
    WHERE `a`.`routing_table` = "' .. table_name .. '" \
    ORDER BY `a`.`position`, `b`.`position`';

  local last_id = 0;
  self.database:query(sql_query, function(route)
    if last_id ~= tonumber(route.call_route_id) then
      last_id = tonumber(route.call_route_id);
      table.insert(routing_table, {id = route.call_route_id, name = route.name, endpoint_type = route.endpoint_type , endpoint_id = route.endpoint_id, elements = {} });
    end
    
    table.insert(routing_table[#routing_table].elements, {
      var_in = route.var_in, 
      var_out = route.var_out, 
      pattern = route.pattern,
      replacement = route.replacement, 
      action = route.action,
      mandatory = common.str.to_b(route.mandatory),
    }); 
  end);

  self.routing_tables[table_name] = routing_table;

  return routing_table;
end


function Router.element_match(self, pattern, search_string, replacement, route_variables)
  local success, result = pcall(string.find, search_string, pattern);

  if not success then
    self.log:error('ELEMENT_ERROR - table error - pattern: ', pattern, ', search_string: ', search_string);
  elseif result then
    local replace_by = common.array.expand_variables(replacement, route_variables, self.variables)
    result = search_string:gsub(pattern, replace_by);
    if self.log_details then
      self.log:debug('ELEMENT_MATCH - ', search_string, ' ~= ', pattern, ' => ', replacement, ' => ', replace_by);
    end
    return true, result;
  end

  if self.log_details then
    self.log:debug('ELEMENT_NO_MATCH - ', search_string, ' != ', pattern);
  end
  return false;
end


function Router.element_match_group(self, pattern, groups, replacement, use_key, route_variables, variable_name)
  if type(groups) ~= 'table' then
    self.log:debug('ELEMENT_FIND_IN_ARRAY - no such array: ', variable_name, ', use_keys: ', tostring(use_key));
    return false;
  end

  if self.log_details then
    self.log:debug('ELEMENT_FIND_IN_ARRAY - array: ', variable_name, ', use_keys: ', tostring(use_key));
  end

  for key, value in pairs(groups) do
    if use_key then 
      value = key;
    end
    result, replaced_value = self:element_match(pattern, tostring(value), replacement, route_variables);
    if result then
      return true, replaced_value;
    end
  end
end


function Router.route_match(self, route)
  local destination = {
    gateway = 'gateway' .. route.endpoint_id,
    ['type'] = route.endpoint_type,
    id = route.endpoint_id,
    destination_number = common.array.try(self, 'caller.destination_number'),
    channel_variables = {},
    route_id = route.id,
  };

  local route_matches = false;

  for index=1, #route.elements do
    local result = false;
    local replacement = nil;

    local element = route.elements[index];

    if self.log_details then
      self.log:debug('ROUTE_ELEMENT ', element.id, ' - var_in: ', element.var_in, ', var_out: ', element.var_out, ', action: ', element.action, ', mandatory: ', element.mandatory);
    end

    if element.action ~= 'none' then
      if common.str.blank(element.var_in) or common.str.blank(element.pattern) and element.action == 'set' then
        result = true;
        replacement = common.array.expand_variables(element.replacement, destination, self.variables);
      else
        local command, variable_name = common.str.partition(element.var_in, ':');

        if not command or not variable_name then
          local search_string = tostring(common.array.try(destination, element.var_in) or common.array.try(self.caller, element.var_in));
          result, replacement = self:element_match(tostring(element.pattern), search_string, tostring(element.replacement), destination);
        elseif command == 'var' then
          local search_string = tostring(common.array.try(self.caller, variable_name));
          result, replacement = self:element_match(tostring(element.pattern), search_string, tostring(element.replacement));
        elseif command == 'key' or command == 'val' then
          local groups = common.array.try(destination, variable_name) or common.array.try(self.caller, variable_name);
          result, replacement = self:element_match_group(tostring(element.pattern), groups, tostring(element.replacement), command == 'key', destination, variable_name);
        elseif command == 'chv' then
          local search_string = self.caller:to_s(variable_name);
          result, replacement = self:element_match(tostring(element.pattern), search_string, tostring(element.replacement));
        elseif command == 'hdr' then
          local search_string = self.caller:to_s('sip_h_' .. variable_name);
          result, replacement = self:element_match(tostring(element.pattern), search_string, tostring(element.replacement));
        end
      end

      if element.action == 'not_match' then
        result = not result;
      end

      if not result then
        if element.mandatory then
          return false;
        end
      else
        if not common.str.blank(element.var_out) then
          local command, variable_name = common.str.partition(element.var_out, ':');
          if not command or not variable_name or command == 'var' then
            common.array.set(destination, element.var_out, replacement);
          elseif command == 'chv' then
            destination.channel_variables[variable_name] = replacement;
          elseif command == 'hdr' then
            destination.channel_variables['sip_h_' .. variable_name] = replacement;
          end
        end

        if element.action == 'match' or element.action == 'not_match' then
          route_matches = true;
        end
      end 
    end
  end

  if route_matches then
    destination.number = destination.number or destination.destination_number;
    return destination;
  end;

  return nil;
end


function Router.route_run(self, table_name, find_first)
  local routing_table = self:read_table(table_name);
  local routes = {};

  if type(routing_table) == 'table' then
    for index=1, #routing_table do
      if self.log_details then
        self.log:info('ROUTE_',table_name:upper(),' ', index,' - ', table_name,'=', routing_table[index].id, '/', routing_table[index].name);
      end    
      local route = self:route_match(routing_table[index]);
      if route then
        table.insert(routes, route);
        self.log:info('ROUTE ', #routes,' - ', table_name,'=', routing_table[index].id, '/', routing_table[index].name, ', destination: ', route.type, '=', route.id, ', destination_number: ', route.destination_number);
        if find_first then
          return route;
        end
      else
        self.log:debug('ROUTE_NO_MATCH - ', table_name, '=', routing_table[index].id, '/', routing_table[index].name); 
      end
    end
  end

  if not find_first then
    return routes;
  end
end
