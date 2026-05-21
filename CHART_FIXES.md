# Chart Rendering Fixes

## Issues Fixed

### 1. Missing Date Adapter
**Problem**: Chart.js time scale requires a date adapter library to parse time data.

**Fix**: Added chartjs-adapter-date-fns to the HTML:
```html
<script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3.0.0/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
```

### 2. Incorrect Data Format
**Problem**: When using Chart.js time scale, data should be an array of {x, y} objects, not separate labels and data arrays.

**Fix**: Changed data structure from:
```javascript
// Old (incorrect)
data: {
    labels: timestamps,
    datasets: [{ data: values }]
}
```

To:
```javascript
// New (correct)
const chartData = timestamps.map((time, idx) => ({
    x: time,
    y: values[idx]
}));

data: {
    datasets: [{ data: chartData }]
}
```

### 3. Added Debug Logging
Added console.log statements to help diagnose issues:
- Chart data validation
- Canvas element checks
- Data point counts
- Processing status

## Testing

### Verify Charts Work

1. Open the generated HTML in a browser
2. Open browser console (F12 → Console tab)
3. Look for debug messages:
   - "generateReport called"
   - "Processing X clusters"
   - "Memory data for memory-chart-0: X points"
   - "CPU data for cpu-chart-0: X points"

### Expected Behavior

- Each cluster should have individual CPU and memory charts
- Charts should display time-series data with smooth lines
- Hover tooltips should show exact values and timestamps
- Version change markers (red dashed lines) should appear where versions changed
- Pod restart markers (orange lines) should appear where restarts occurred

## Troubleshooting

If charts still don't display:

1. **Check browser console for errors**
   - Red error messages indicate JavaScript issues
   - Look for "Canvas not found" or "No timeseries data" warnings

2. **Verify data exists**
   - Open console and type: `healthData[0].health_checks`
   - Look for "resource_leak_detection" check
   - Verify it has `memory_timeseries` and `cpu_timeseries` arrays

3. **Check internet connection**
   - Chart.js and date adapter load from CDN
   - If offline, charts won't render

4. **Verify Chart.js loaded**
   - In console, type: `Chart.version`
   - Should show version number like "4.4.0"
   - If undefined, Chart.js failed to load

## Files Modified

1. **generate_html_report.sh**:
   - Added date adapter script tag
   - Fixed chart data format
   - Added debug logging
   - Enhanced chart options

## Next Steps

Once charts are confirmed working:
- Remove excessive debug logging
- Add export functionality (PNG/PDF)
- Add chart comparison view
- Implement offline mode with bundled Chart.js
