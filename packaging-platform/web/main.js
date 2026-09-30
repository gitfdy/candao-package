import { createApp } from 'vue';
import PrimeVue from 'primevue/config';
import { definePreset } from '@primeuix/themes';
import Aura from '@primeuix/themes/aura';
import App from './App.vue';
import './style.css';
import './workflow.css';
import './polish.css';

window._hmt = window._hmt || [];
const analytics = document.createElement('script');
analytics.async = true;
analytics.src = 'https://hm.baidu.com/hm.js?f6f92b1fec97f07fd681de3df798f2e4';
document.head.appendChild(analytics);

const app = createApp(App);
app.use(PrimeVue, { theme: { preset: definePreset(Aura, { semantic: { primary: { 50: '#e8f6f0', 100: '#d3eee1', 200: '#a8dcc7', 300: '#73c8aa', 400: '#35ad88', 500: '#008b70', 600: '#007c69', 700: '#006b5a', 800: '#15534a', 900: '#143f3a', 950: '#102d2c' } } }), options: { darkModeSelector: false } } });
app.mount('#app');
