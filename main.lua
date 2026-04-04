local plugin_label = 'wonder_city'

local gui          = require 'gui'
local settings     = require 'core.settings'
local task_manager = require 'core.task_manager'
local external     = require 'core.external'

local local_player, player_position
local debounce_time = nil
local debounce_timeout = 0

local update_locals = function  ()
    local_player = get_local_player()
    player_position = local_player and local_player:get_position()
end
local main_pulse = function  ()
    if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then return end
    debounce_time = get_time_since_inject()
    settings:update_settings()
    if not local_player then return end
    if not settings.enabled or not settings.get_keybind_state() then return end
    -- if orbwalker.get_orb_mode() ~= 3 then
    --     orbwalker.set_clear_toggle(true)
    --     orbwalker.set_block_movement(true)
    -- end
    if local_player:is_dead() then
        revive_at_checkpoint()
    else
        task_manager.execute_tasks()
    end
end
local cp_colors = {
    accept                = color_green(220),
    portal                = color_red(220),
    inventory_slot_0      = color_white(200),
    sort_button           = color_cyan(220),
    bargain_opener        = color_yellow(220),
    scroll_bar            = color_green(220),
    core_stats            = color_cyan(220),
    primary_resource      = color_blue(220),
    resistances           = color_purple(220),
    offensive_legendaries = color_orange(220),
    defensive_legendaries = color_red(180),
    utility_legendaries   = color_green(180),
    mobility_legendaries  = color_blue(180),
    resource_legendaries  = color_yellow(180),
}
local draw_crosshair = function (cx, cy, label, color)
    local arm = 12
    graphics.line(vec2:new(cx - arm, cy), vec2:new(cx + arm, cy), color, 2)
    graphics.line(vec2:new(cx, cy - arm), vec2:new(cx, cy + arm), color, 2)
    graphics.circle_2d(vec2:new(cx, cy), 5, color, 1)
    graphics.text_2d(label, vec2:new(cx + 14, cy - 8), 14, color)
end
local render_pulse = function  ()
    if settings.show_click_points then
        if not settings.enable_bargains then
            draw_crosshair(settings.accept_button_x, settings.accept_button_y, 'Accept', cp_colors.accept)
        else
            draw_crosshair(settings.portal_button_x, settings.portal_button_y, 'Open Portal', cp_colors.portal)
            draw_crosshair(settings.inventory_slot_0_x, settings.inventory_slot_0_y, 'Slot 0', cp_colors.inventory_slot_0)
            for _, key in ipairs(gui.bargain_cp_keys) do
                local cp = settings.bargain_cp[key]
                draw_crosshair(cp.x, cp.y, gui.bargain_cp_labels[key], cp_colors[key])
            end
        end
    end
    if not (settings.get_keybind_state()) then return end
    if not local_player or not settings.enabled then return end
    local current_task = task_manager.get_current_task()
    if current_task then
        local msg = "WonderCity: " .. current_task.name
        if current_task.status ~= nil then
            msg = "WonderCity: " .. current_task.name .. ' (' .. current_task.status .. ')'
        end
        local x_pos = get_screen_width()/2 - (#msg * 5.5)
        local y_pos = 80
        graphics.text_2d(msg, vec2:new(x_pos, y_pos), 20, color_white(255))
    end
end

on_update(function()
    update_locals()
    main_pulse()
end)

on_render_menu(function ()
    gui.render()
end)
on_render(render_pulse)
WonderCityPlugin = external
