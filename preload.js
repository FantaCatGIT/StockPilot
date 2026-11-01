'use strict';
const { contextBridge, ipcRenderer } = require('electron');
const CHANNELS = ['state', 'log', 'nav'];
contextBridge.exposeInMainWorld('sp', {
  call: (method, ...args) => ipcRenderer.invoke('sp', method, args),
  on: (ch, cb) => {
    if (!CHANNELS.includes(ch)) return () => { };
    const h = (_e, d) => cb(d);
    ipcRenderer.on(ch, h);
    return () => ipcRenderer.removeListener(ch, h);
  },
  platform: process.platform,
});
