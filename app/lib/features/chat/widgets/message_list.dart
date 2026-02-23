import 'package:flutter/material.dart';

import '../../../models/message.dart';
import '../../../shared/responsive.dart';
import 'message_bubble.dart';

/// A scrollable list of chat messages.
///
/// Uses [ListView.builder] in reverse mode so that the newest message
/// is always at the bottom and the list auto-scrolls there.
class MessageList extends StatefulWidget {
  final List<Message> messages;

  const MessageList({super.key, required this.messages});

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Scroll to bottom when a new message arrives.
    if (widget.messages.length > oldWidget.messages.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller.hasClients) {
          _controller.animateTo(
            0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return const Center(
        child: Text(
          'No messages yet',
          style: TextStyle(color: Colors.white38),
        ),
      );
    }

    return ListView.builder(
      controller: _controller,
      reverse: true,
      padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding, vertical: context.rSpacing * 2),
      itemCount: widget.messages.length,
      itemBuilder: (context, index) {
        final message = widget.messages[widget.messages.length - 1 - index];
        return Padding(
          padding: EdgeInsets.only(bottom: context.rSpacing),
          child: MessageBubble(message: message),
        );
      },
    );
  }
}
