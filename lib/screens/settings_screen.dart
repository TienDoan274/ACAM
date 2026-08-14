import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../utils/constants.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  DetectionMode _selectedMode = DetectionMode.autoGrid;
  bool _autoSave = true;
  String _exportFormat = 'png';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    final modeIndex = prefs.getInt(SettingsKeys.detectionMode) ?? 0;
    _selectedMode = DetectionMode.values[modeIndex];
    _autoSave = prefs.getBool(SettingsKeys.autoSave) ?? true;
    _exportFormat = prefs.getString(SettingsKeys.exportFormat) ?? 'png';

    setState(() {});
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setInt(
      SettingsKeys.detectionMode,
      DetectionMode.values.indexOf(_selectedMode),
    );
    await prefs.setBool(SettingsKeys.autoSave, _autoSave);
    await prefs.setString(SettingsKeys.exportFormat, _exportFormat);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          // Default Detection Mode (the actual mode is picked at runtime
          // in the preview screen; this sets the starting point)
          _buildSection(
            title: 'Default Detection',
            children: [
              RadioListTile<DetectionMode>(
                title: const Text('Auto Grid'),
                subtitle: const Text('Grid corners + bilinear grid (default)'),
                value: DetectionMode.autoGrid,
                groupValue: _selectedMode,
                onChanged: (mode) {
                  setState(() {
                    _selectedMode = mode!;
                  });
                  _saveSettings();
                },
              ),
              RadioListTile<DetectionMode>(
                title: const Text('Manual Adjust'),
                subtitle: const Text('5-DOF grid adjustment'),
                value: DetectionMode.manualGrid,
                groupValue: _selectedMode,
                onChanged: (mode) {
                  setState(() {
                    _selectedMode = mode!;
                  });
                  _saveSettings();
                },
              ),
              RadioListTile<DetectionMode>(
                title: const Text('YOLO Detect'),
                subtitle: const Text('ML-based well detection'),
                value: DetectionMode.yoloDetect,
                groupValue: _selectedMode,
                onChanged: (mode) {
                  setState(() {
                    _selectedMode = mode!;
                  });
                  _saveSettings();
                },
              ),
            ],
          ),

          const Divider(),

          // Storage Options
          _buildSection(
            title: 'Storage',
            children: [
              SwitchListTile(
                title: const Text('Auto-save to History'),
                subtitle: const Text('Automatically save results after processing'),
                value: _autoSave,
                onChanged: (value) {
                  setState(() {
                    _autoSave = value;
                  });
                  _saveSettings();
                },
              ),
            ],
          ),

          const Divider(),

          // Export Format
          _buildSection(
            title: 'Export Format',
            children: [
              RadioListTile<String>(
                title: const Text('PNG'),
                subtitle: const Text('High quality images'),
                value: 'png',
                groupValue: _exportFormat,
                onChanged: (value) {
                  setState(() {
                    _exportFormat = value!;
                  });
                  _saveSettings();
                },
              ),
              RadioListTile<String>(
                title: const Text('JPEG'),
                subtitle: const Text('Smaller file size'),
                value: 'jpeg',
                groupValue: _exportFormat,
                onChanged: (value) {
                  setState(() {
                    _exportFormat = value!;
                  });
                  _saveSettings();
                },
              ),
            ],
          ),

          const Divider(),

          // About
          _buildSection(
            title: 'About',
            children: [
              ListTile(
                title: const Text('Version'),
                subtitle: const Text('1.0.0+1'),
              ),
              ListTile(
                title: const Text('Model Information'),
                subtitle: const Text('View pipeline details'),
                trailing: const Icon(Icons.info_outline),
                onTap: _showModelInfo,
              ),
              ListTile(
                title: const Text('License'),
                subtitle: const Text('AGPL-3.0'),
                trailing: const Icon(Icons.description),
                onTap: _showLicense,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSection({required String title, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey[600],
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  void _showModelInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Model Information'),
        content: const SingleChildScrollView(
          child: MarkdownBody(
            data: '''
## Pipeline Components

### Stage 1: Corner Regression
- **Model**: EfficientNet-B3
- **Input**: 896×896 grayscale image
- **Output**: 4 corners (x, y coordinates)
- **Size**: ~30 MB (TFLite quantized)

### Stage 2: Well Detection
- **Mode**: Parametric Grid Interpolation
- **Method**: Bilinear interpolation from 4 corners
- **Grid**: 16 rows × 24 columns = 384 wells
- **Model Size**: 0 MB (deterministic)

### Stage 3: Classification
- **Model**: Simple Neural Network
- **Input**: 64×64 well crop
- **Output**: 3 classes (Growth, NoGrowth, NoAgar)
- **Size**: ~1 MB (TFLite)

## Performance
- **Processing Time**: ~100-200 ms on mid-range device
- **Accuracy**: >95% F1 score
- **Offline**: Fully on-device inference

## Engine
- **Framework**: TensorFlow Lite
- **Platform**: Android + iOS (Flutter)
            ''',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showLicense() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('License'),
        content: const SingleChildScrollView(
          child: MarkdownBody(
            data: '''
## AGPL-3.0 License

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published
by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

## Third-Party Licenses

This app uses the following open-source libraries:
- Flutter (BSD-3-Clause)
- TensorFlow Lite (Apache-2.0)
- camera (BSD-3-Clause)
- image_picker (BSD-3-Clause)
- sqflite (BSD-3-Clause)

Full license text available in the source code repository.
            ''',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
