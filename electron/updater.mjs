// In-app auto-update is off: this fork is handed out internally as a
// signed+notarized DMG, not via a public GitHub feed. New versions go out
// the same way. IPC handlers stay registered so a stale renderer never throws.
import { ipcMain } from "electron";

let win = null;
let state = { status: "idle" };

function setState(patch) {
  state = { ...state, ...patch };
  try {
    win?.webContents?.send("update:state", state);
  } catch {
    /* window gone */
  }
}

export function registerUpdaterIpc() {
  ipcMain.handle("update:get-state", () => state);
  ipcMain.handle("update:check", async () => {});
  ipcMain.handle("update:download", async () => {});
  ipcMain.handle("update:install", async () => {});
}

export function startUpdater(mainWindow) {
  win = mainWindow;
  setState({ status: "idle" });
}
