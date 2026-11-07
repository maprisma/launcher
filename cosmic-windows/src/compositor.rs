use crate::Result;
use cosmic_client_toolkit::cosmic_protocols::{
    toplevel_info::v1::client::zcosmic_toplevel_handle_v1::State as TopState,
    toplevel_management::v1::client::zcosmic_toplevel_manager_v1 as manager,
};
use cosmic_client_toolkit::{
    GlobalData,
    toplevel_info::{ToplevelInfoHandler, ToplevelInfoState},
    toplevel_management::ToplevelManagerState,
    workspace::{Workspace, WorkspaceHandler, WorkspaceState},
};
use sctk::{
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    seat::{Capability, SeatHandler, SeatState},
};
use serde_json::{Value, json};
use std::{
    os::fd::{AsFd, AsRawFd},
    time::{Duration, Instant},
};
use wayland_client::{
    Connection, Dispatch, QueueHandle, WEnum,
    globals::registry_queue_init,
    protocol::{wl_output::WlOutput, wl_seat::WlSeat},
};
use wayland_protocols::ext::foreign_toplevel_list::v1::client::ext_foreign_toplevel_handle_v1::ExtForeignToplevelHandleV1;
struct State {
    registry: RegistryState,
    outputs: OutputState,
    seats: SeatState,
    ws: WorkspaceState,
    tops: ToplevelInfoState,
    manager: Option<ToplevelManagerState>,
    info_ready: bool,
    caps: Vec<WEnum<manager::ZcosmicToplelevelManagementCapabilitiesV1>>,
}
impl ProvidesRegistryState for State {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry
    }
    sctk::registry_handlers!(OutputState, SeatState);
}
impl OutputHandler for State {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.outputs
    }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlOutput) {}
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlOutput) {}
}
impl SeatHandler for State {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seats
    }
    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlSeat) {}
    fn new_capability(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlSeat, _: Capability) {}
    fn remove_capability(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: WlSeat,
        _: Capability,
    ) {
    }
    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlSeat) {}
}
impl WorkspaceHandler for State {
    fn workspace_state(&mut self) -> &mut WorkspaceState {
        &mut self.ws
    }
    fn done(&mut self) {}
}
impl ToplevelInfoHandler for State {
    fn toplevel_info_state(&mut self) -> &mut ToplevelInfoState {
        &mut self.tops
    }
    fn new_toplevel(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &ExtForeignToplevelHandleV1,
    ) {
    }
    fn update_toplevel(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &ExtForeignToplevelHandleV1,
    ) {
    }
    fn toplevel_closed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &ExtForeignToplevelHandleV1,
    ) {
    }
    fn info_done(&mut self, _: &Connection, _: &QueueHandle<Self>) {
        self.info_ready = true;
    }
}
impl Dispatch<manager::ZcosmicToplevelManagerV1, GlobalData> for State {
    fn event(
        s: &mut Self,
        _: &manager::ZcosmicToplevelManagerV1,
        e: manager::Event,
        _: &GlobalData,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let manager::Event::Capabilities { capabilities } = e {
            s.caps = capabilities
                .chunks_exact(4)
                .map(|c| WEnum::from(u32::from_ne_bytes(c.try_into().unwrap())))
                .collect();
        }
    }
}
sctk::delegate_output!(State);
sctk::delegate_registry!(State);
sctk::delegate_seat!(State);
cosmic_client_toolkit::delegate_workspace!(State);
cosmic_client_toolkit::delegate_toplevel_info!(State);
impl State {
    fn output_name(&self, o: &WlOutput) -> String {
        self.outputs
            .info(o)
            .and_then(|i| i.name)
            .unwrap_or_default()
    }
    fn output(&self) -> Option<WlOutput> {
        self.tops
            .toplevels()
            .find(|t| t.state.contains(&TopState::Activated))
            .and_then(|t| t.output.iter().min_by_key(|o| self.output_name(o)).cloned())
            .or_else(|| self.outputs.outputs().min_by_key(|o| self.output_name(o)))
    }
    fn ordered(&self) -> Vec<&Workspace> {
        let output = self.output();
        let group = self
            .ws
            .workspace_groups()
            .find(|g| output.as_ref().is_some_and(|o| g.outputs.contains(o)));
        let mut w: Vec<_> = self
            .ws
            .workspaces()
            .filter(|w| {
                group
                    .as_ref()
                    .is_some_and(|g| g.workspaces.contains(&w.handle))
            })
            .collect();
        w.sort_by(|a, b| a.coordinates.cmp(&b.coordinates).then(a.name.cmp(&b.name)));
        w
    }
    fn window_json(&self) -> Value {
        let ordered = self.ordered();
        json!({"available":true,"windows":self.tops.toplevels().map(|t|
            window_json(&t.identifier, &t.app_id, &t.title,
                ordered.iter().position(|w|t.workspace.contains(&w.handle)).map(|i|i+1),
                t.state.contains(&TopState::Activated))).collect::<Vec<_>>()})
    }
    fn action(&self, a: &[String]) -> Result<Value> {
        let cmd = a[0].as_str();
        match cmd {
            "list" if a.len() == 1 => return Ok(self.window_json()),
            "close" | "activate" if a.len() == 2 => {
                let t = self
                    .tops
                    .toplevels()
                    .find(|t| t.identifier == a[1])
                    .ok_or("not_found")?;
                let h = t.cosmic_toplevel.as_ref().ok_or("management unavailable")?;
                let m = &self
                    .manager
                    .as_ref()
                    .ok_or("management unavailable")?
                    .manager;
                let capability = match cmd {
                    "close" => manager::ZcosmicToplelevelManagementCapabilitiesV1::Close,
                    _ => manager::ZcosmicToplelevelManagementCapabilitiesV1::Activate,
                };
                if !self.caps.contains(&WEnum::Value(capability)) {
                    return Err("management capability unavailable".into());
                }
                match cmd {
                    "close" => m.close(h),
                    _ => m.activate(h, &self.seats.seats().next().ok_or("no seat")?),
                }
            }
            _ => return Err("invalid arguments".into()),
        };
        Ok(json!({"done":true}))
    }
}
pub fn run(a: &[String]) -> Result<Value> {
    let conn = Connection::connect_to_env().map_err(|e| e.to_string())?;
    let (globals, mut queue) = registry_queue_init::<State>(&conn).map_err(|e| e.to_string())?;
    let qh = queue.handle();
    let registry = RegistryState::new(&globals);
    let mut state = State {
        outputs: OutputState::new(&globals, &qh),
        seats: SeatState::new(&globals, &qh),
        ws: WorkspaceState::new(&registry, &qh),
        tops: ToplevelInfoState::try_new(&registry, &qh).ok_or("toplevel protocol unavailable")?,
        manager: ToplevelManagerState::try_new(&registry, &qh),
        registry,
        caps: vec![],
        info_ready: false,
    };
    if state.manager.is_none() || state.tops.cosmic_toplevel_info.is_none() {
        return Err("COSMIC management unavailable".into());
    }
    // Initial object creation and dependent COSMIC info arrive over successive roundtrips.
    for _ in 0..3 {
        queue.roundtrip(&mut state).map_err(|e| e.to_string())?;
    }
    // COSMIC batches initial toplevel properties on its refresh timer, after sync replies.
    // Roundtrips alone can otherwise incorrectly report an empty desktop.
    let deadline = Instant::now() + Duration::from_millis(500);
    while !state.info_ready && Instant::now() < deadline {
        queue
            .dispatch_pending(&mut state)
            .map_err(|e| e.to_string())?;
        conn.flush().map_err(|e| e.to_string())?;
        if let Some(guard) = queue.prepare_read() {
            let mut fd = libc::pollfd {
                fd: conn.as_fd().as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            let n = unsafe { libc::poll(&mut fd, 1, 25) };
            if n < 0 {
                return Err(std::io::Error::last_os_error().to_string());
            }
            if n > 0 {
                guard.read().map_err(|e| e.to_string())?;
            }
        }
    }
    queue
        .dispatch_pending(&mut state)
        .map_err(|e| e.to_string())?;
    let value = state.action(a)?;
    queue.roundtrip(&mut state).map_err(|e| e.to_string())?;
    Ok(value)
}

fn window_json(
    id: &str,
    app_id: &str,
    title: &str,
    workspace: Option<usize>,
    active: bool,
) -> Value {
    json!({"id":id,"app_id":app_id,"title":title,"workspace":workspace,"active":active})
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn window_json_preserves_opaque_ids_and_escapes_titles() {
        let value = window_json(
            "opaque/id",
            "chrome-app-Default",
            "YouTube \"live\"\n🎵",
            Some(2),
            false,
        );
        let encoded = serde_json::to_string(&value).unwrap();
        let decoded: Value = serde_json::from_str(&encoded).unwrap();
        assert_eq!(
            decoded,
            json!({"id":"opaque/id","app_id":"chrome-app-Default",
            "title":"YouTube \"live\"\n🎵","workspace":2,"active":false})
        );
        assert!(window_json("x", "", "", None, true)["workspace"].is_null());
    }
}
