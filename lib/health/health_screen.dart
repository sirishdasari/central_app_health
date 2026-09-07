import 'package:flutter/material.dart';
import 'package:health/health.dart';

import 'health_service.dart';

class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key});

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  final HealthService healthService = HealthService();

  List<HealthDataPoint> data = [];

  bool loading = false;

  Future<void> loadHealthData() async {
    setState(() {
      loading = true;
    });

    final permissionGranted =
        await healthService.requestPermissions();

    if (!permissionGranted) {
      setState(() {
        loading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Health Connect permission was not granted',
            ),
          ),
        );
      }

      return;
    }

    final result =
        await healthService.getTodayHealthData();

    setState(() {
      data = result;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Health Connect'),
      ),
      body: Column(
        children: [
          const SizedBox(height: 20),

          ElevatedButton(
            onPressed: loading ? null : loadHealthData,
            child: Text(
              loading
                  ? 'Reading...'
                  : 'Read Health Data',
            ),
          ),

          const SizedBox(height: 20),

          Expanded(
            child: ListView.builder(
              itemCount: data.length,
              itemBuilder: (context, index) {
                final item = data[index];

                return Card(
                  child: ListTile(
                    title: Text(
                      item.type.toString(),
                    ),
                    subtitle: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Value: ${item.value}',
                        ),
                        Text(
                          'Unit: ${item.unit}',
                        ),
                        Text(
                          'From: ${item.dateFrom}',
                        ),
                        Text(
                          'To: ${item.dateTo}',
                        ),
                        Text(
                          'Source: ${item.sourceName}',
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}