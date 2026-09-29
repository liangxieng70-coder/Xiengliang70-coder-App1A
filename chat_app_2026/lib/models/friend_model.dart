import 'package:cloud_firestore/cloud_firestore.dart';

class FriendModel {
  final String friendId;
  final String email;
  final String displayName;
  final String? photoUrl;
  final bool isOnline;
  final DateTime? lastSeen;
  final bool isPlaceholder;
  final DateTime addedAt;

  FriendModel({
    required this.friendId,
    required this.email,
    required this.displayName,
    this.photoUrl,
    required this.isOnline,
    this.lastSeen,
    this.isPlaceholder = false,
    required this.addedAt,
  });

  factory FriendModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return FriendModel(
      friendId: doc.id,
      email: data['email'] ?? '',
      displayName: data['displayName'] ?? data['email']?.split('@').first ?? '?',
      photoUrl: data['photoUrl'],
      isOnline: data['isOnline'] ?? false,
      lastSeen: data['lastSeen'] != null
          ? (data['lastSeen'] as Timestamp).toDate()
          : null,
      isPlaceholder: data['isPlaceholder'] ?? false,
      addedAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'email': email,
      'displayName': displayName,
      'photoUrl': photoUrl,
      'isOnline': isOnline,
      'lastSeen': lastSeen != null ? Timestamp.fromDate(lastSeen!) : null,
      'isPlaceholder': isPlaceholder,
    };
  }
}
