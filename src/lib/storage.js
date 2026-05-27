import { state } from '../state/state.js'

export function saveSelectedStore(storeId, storeName) {
  state.selectedStoreId   = storeId
  state.selectedStoreName = storeName
  localStorage.setItem('gotya_store_id',   storeId)
  localStorage.setItem('gotya_store_name', storeName)
}

export function loadSelectedStore() {
  state.selectedStoreId   = localStorage.getItem('gotya_store_id')
  state.selectedStoreName = localStorage.getItem('gotya_store_name')
}

export function saveSelectedOutlet(outletId, outletName) {
  state.selectedOutletId   = outletId
  state.selectedOutletName = outletName
  localStorage.setItem('gotya_outlet_id',   outletId)
  localStorage.setItem('gotya_outlet_name', outletName)
}

export function loadSelectedOutlet() {
  state.selectedOutletId   = localStorage.getItem('gotya_outlet_id')
  state.selectedOutletName = localStorage.getItem('gotya_outlet_name')
}

export function clearSelectedOutlet() {
  state.selectedOutletId   = null
  state.selectedOutletName = null
  localStorage.removeItem('gotya_outlet_id')
  localStorage.removeItem('gotya_outlet_name')
}
