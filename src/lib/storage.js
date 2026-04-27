import { state } from '../state/state.js'

export function saveSelectedStore(storeId, storeName) {
  state.selectedStoreId = storeId
  state.selectedStoreName = storeName
  localStorage.setItem('libber_store_id', storeId)
  localStorage.setItem('libber_store_name', storeName)
}

export function loadSelectedStore() {
  state.selectedStoreId = localStorage.getItem('libber_store_id')
  state.selectedStoreName = localStorage.getItem('libber_store_name')
}
