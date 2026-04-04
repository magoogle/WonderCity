local plugin_label = 'wonder_city' -- change to your plugin name

local gui = require 'gui'
local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local path = require 'data.path'

local status_enum = {
    IDLE     = 'idle',
    WALKING  = 'walking to ',
    OPENING  = 'opening undercity',
    ENTERING = 'entering undercity',
    WAITING  = 'waiting ',
}

-- Bargain sub-steps (bargain flow only)
local BARGAIN = {
    SORT         = 1,  -- click the Sort button
    SORT_WAIT    = 2,  -- wait for sort to settle
    TRIBUTE      = 3,  -- right-click the chosen tribute in inventory
    TRIBUTE_WAIT = 4,  -- wait after right-click
    OPEN_MENU    = 5,  -- click bargain menu opener, wait for menu
    SCROLL       = 6,  -- click scroll bar if needed
    SELECT       = 7,  -- click the bargain option
    READY        = 8,  -- bargain selected, proceed to Open Portal
}

-- Inventory grid is 4 columns wide; slot index from get_item_slot_index(item, 4)
local INVENTORY_COLS = 4

local task = {
    name            = 'enter_undercity',
    status          = status_enum['IDLE'],
    interacted      = false,
    debounce_time   = -1,
    -- no-bargain flow
    accept_clicked  = false,
    -- bargain flow
    bargain_step       = 0,
    bargain_step_time  = -1,
    bargain_attempt_idx = 0,
    bargain_walk_away  = false,
    portal_click_start = -1,
}

local get_sorted_bargains = function ()
    local result = {}
    for i, bargain in ipairs(gui.bargains_data) do
        local p = settings.bargain_priorities[i]
        if p and p > 0 then
            result[#result + 1] = {idx = i, priority = p, bargain = bargain}
        end
    end
    table.sort(result, function(a, b) return a.priority < b.priority end)
    return result
end

local reset_interaction_state = function ()
    task.accept_clicked     = false
    task.bargain_step       = 0
    task.bargain_step_time  = -1
    task.bargain_attempt_idx = 0
    task.portal_click_start = -1
end

-- Returns the screen position of a sigil inventory slot (0-based index, 4-col grid)
local slot_screen_pos = function (slot_index)
    local col = slot_index % INVENTORY_COLS
    local row = math.floor(slot_index / INVENTORY_COLS)
    local x = settings.inventory_slot_0_x + col * settings.inventory_cell_size
    local y = settings.inventory_slot_0_y + row * settings.inventory_cell_size
    return x, y
end

-- ── No-bargain flow ──────────────────────────────────────────────────────────
-- Obelisk is already interacted; just click Accept and wait for portal
local open_portal_simple = function ()
    if not task.accept_clicked then
        utility.send_mouse_click(settings.accept_button_x, settings.accept_button_y)
        task.accept_clicked = true
    end
    task.status = status_enum['WAITING'] .. 'for portal'
end

-- ── Bargain flow ─────────────────────────────────────────────────────────────
local open_portal_bargain = function ()
    local now = get_time_since_inject()

    -- ── Step 1: Sort inventory ──
    if task.bargain_step == 0 then
        task.bargain_step = BARGAIN.SORT
    end

    if task.bargain_step == BARGAIN.SORT then
        local cp = settings.bargain_cp['sort_button']
        utility.send_mouse_click(cp.x, cp.y)
        task.bargain_step = BARGAIN.SORT_WAIT
        task.bargain_step_time = now
        task.status = status_enum['WAITING'] .. 'sort'
        return
    end

    if task.bargain_step == BARGAIN.SORT_WAIT then
        if now < task.bargain_step_time + 0.5 then
            task.status = status_enum['WAITING'] .. 'sort'
            return
        end
        task.bargain_step = BARGAIN.TRIBUTE
    end

    -- ── Step 2: Right-click the chosen tribute ──
    if task.bargain_step == BARGAIN.TRIBUTE then
        local lp = get_local_player()
        if lp then
            local key_items = lp:get_dungeon_key_items()
            if key_items and #key_items > 0 then
                -- Pick best-priority tribute
                local best_item, best_priority = nil, math.huge
                for _, item in ipairs(key_items) do
                    local p = settings.tribute_priorities[item:get_sno_id()]
                    if p and p > 0 and p < best_priority then
                        best_item = item
                        best_priority = p
                    end
                end
                local chosen = best_item or key_items[1]
                -- Get its slot index (bag type 4 = sigil/dungeon key bag)
                local slot = lp:get_item_slot_index(chosen, 4)
                local sx, sy = slot_screen_pos(slot)
                utility.send_mouse_right_click(sx, sy)
                task.bargain_step = BARGAIN.TRIBUTE_WAIT
                task.bargain_step_time = now
                task.status = status_enum['WAITING'] .. 'tribute placed'
            end
        end
        return
    end

    if task.bargain_step == BARGAIN.TRIBUTE_WAIT then
        if now < task.bargain_step_time + 0.5 then
            task.status = status_enum['WAITING'] .. 'tribute placed'
            return
        end
        task.bargain_step = BARGAIN.OPEN_MENU
    end

    -- ── Step 3: Select bargain ──
    local sorted = get_sorted_bargains()

    if task.bargain_step == BARGAIN.OPEN_MENU then
        task.bargain_attempt_idx = task.bargain_attempt_idx + 1
        if task.bargain_attempt_idx > #sorted then
            -- No more bargains to try
            task.bargain_step = BARGAIN.READY
        else
            local cp = settings.bargain_cp['bargain_opener']
            utility.send_mouse_click(cp.x, cp.y)
            task.bargain_step_time = now
            task.status = status_enum['WAITING'] .. 'bargain menu'
        end
        return
    end

    -- Waiting for bargain menu to open
    if task.bargain_step == BARGAIN.OPEN_MENU + 0 then end  -- handled above; keep for clarity

    local current = sorted[task.bargain_attempt_idx]

    if task.bargain_step == BARGAIN.OPEN_MENU and now >= task.bargain_step_time + 0.5 then
        if current and current.bargain.needs_scroll then
            local cp = settings.bargain_cp['scroll_bar']
            utility.send_mouse_click(cp.x, cp.y)
            task.bargain_step = BARGAIN.SCROLL
            task.bargain_step_time = now
            task.status = status_enum['WAITING'] .. 'scrolling'
        else
            task.bargain_step = BARGAIN.SELECT
            task.bargain_step_time = now
        end
        return
    elseif task.bargain_step == BARGAIN.OPEN_MENU then
        task.status = status_enum['WAITING'] .. 'bargain menu'
        return
    end

    if task.bargain_step == BARGAIN.SCROLL then
        if now < task.bargain_step_time + 0.3 then
            task.status = status_enum['WAITING'] .. 'scrolling'
            return
        end
        task.bargain_step = BARGAIN.SELECT
        task.bargain_step_time = now
        return
    end

    if task.bargain_step == BARGAIN.SELECT then
        if now < task.bargain_step_time + 0.3 then
            task.status = status_enum['WAITING'] .. 'selecting bargain'
            return
        end
        if current then
            local cp = settings.bargain_cp[current.bargain.cp_key]
            utility.send_mouse_click(cp.x, cp.y)
            task.status = 'bargain: ' .. current.bargain.name
        end
        task.bargain_step = BARGAIN.READY
        task.portal_click_start = -1
        return
    end

    -- ── Step 4: Click Open Portal, handle timeout ──
    if task.bargain_step == BARGAIN.READY then
        if task.portal_click_start < 0 then
            task.portal_click_start = now
        elseif now > task.portal_click_start + settings.bargain_timeout then
            -- Bargain failed — walk away to reset obelisk, retry next priority
            task.bargain_walk_away = true
            task.bargain_step = BARGAIN.OPEN_MENU   -- will increment attempt_idx on next interact
            task.bargain_step_time = -1
            task.portal_click_start = -1
            task.status = 'bargain failed - walking away'
            return
        end
        utility.send_mouse_click(settings.portal_button_x, settings.portal_button_y)
        task.status = status_enum['OPENING']
    end
end

-- ── Common wrapper ────────────────────────────────────────────────────────────
local open_portal = function (delay)
    task.status = status_enum['OPENING']
    local spirit_brazier = utils.get_spirit_brazier()
    if spirit_brazier == nil or spirit_brazier.get_position == nil then return end

    if not loot_manager:is_in_vendor_screen() and not task.interacted then
        interact_object(spirit_brazier)
    elseif not task.interacted then
        task.interacted = true
        reset_interaction_state()
    end

    if loot_manager:is_in_vendor_screen() then
        if settings.enable_bargains then
            open_portal_bargain()
        else
            open_portal_simple()
        end
    elseif delay and
        task.debounce_time + settings.confirm_delay > get_time_since_inject()
    then
        task.status = status_enum['WAITING'] .. 'for confirmation'
        return
    else
        task.interacted = false
    end
    task.debounce_time = get_time_since_inject()
end

local enter_portal = function (portal)
    interact_object(portal)
    BatmobilePlugin.reset(plugin_label)
    tracker.undercity_start_time = get_time_since_inject()
    tracker.exit_trigger_time = nil
    tracker.exit_reset = false
    tracker.boss_trigger_time = nil
    tracker.boss_kill_time = nil
    tracker.enticement = {}
    tracker.done = false
    task.status = status_enum['ENTERING']
end

local walk_to_activator = function (activator)
    BatmobilePlugin.set_target(plugin_label, activator)
    BatmobilePlugin.move(plugin_label)
    task.status = status_enum['WALKING'] .. 'spirit brazier'
end

task.shouldExecute = function ()
    return utils.player_in_zone('Naha_Kurast')
end

task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)

    local player_pos = local_player:get_position()
    local spirit_brazier = utils.get_spirit_brazier()
    local portal = utils.get_entrance_portal()

    -- Walk away from obelisk to reset it after a failed bargain
    if task.bargain_walk_away then
        if spirit_brazier == nil or utils.distance(player_pos, spirit_brazier) > 10 then
            task.bargain_walk_away = false
            task.interacted = false
            -- bargain_attempt_idx kept so next interact tries the next bargain
        else
            BatmobilePlugin.set_target(plugin_label, path[1])
            BatmobilePlugin.move(plugin_label)
            task.status = 'bargain failed - walking away'
        end
        return
    end

    if portal ~= nil then
        if utils.distance(player_pos, portal) > 2 then
            BatmobilePlugin.set_target(plugin_label, portal)
            BatmobilePlugin.move(plugin_label)
            task.status = status_enum['WALKING'] .. 'portal'
        else
            enter_portal(portal)
        end
    elseif spirit_brazier == nil or utils.distance(player_pos, spirit_brazier) > 2 then
        if spirit_brazier ~= nil then
            walk_to_activator(spirit_brazier)
        end
    elseif not settings.party_enabled then
        BatmobilePlugin.clear_target(plugin_label)
        open_portal(false)
    elseif settings.party_mode == 0 then
        BatmobilePlugin.clear_target(plugin_label)
        open_portal(true)
    else
        BatmobilePlugin.clear_target(plugin_label)
        if task.status ~= status_enum['WAITING'] .. 'for portal' and
            settings.use_magoogle_tool and settings.party_enabled and
            settings.party_mode == 1
        then
            -- contact magoogle tool accepting portal
        end
        task.status = status_enum['WAITING'] .. 'for portal'
    end
end

return task
